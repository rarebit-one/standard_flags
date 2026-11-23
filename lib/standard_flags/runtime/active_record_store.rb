require "standard_flags/runtime/models"

module StandardFlags
  module Runtime
    # The default store when runtime rules are on: the four tables written by
    # `bin/rails g standard_flags:migrations`, read through the host's
    # ActiveRecord connection. Required (with ActiveRecord) only when runtime
    # rules are on and no other store is configured.
    #
    # Inside a host transaction each read runs in a savepoint, so a failed
    # read can't abort the host's transaction. Read errors are re-raised as
    # StoreError without the driver's message for membership reads, which
    # could quote a unit key.
    class ActiveRecordStore < Store
      TABLES = %w[standard_flags_rules standard_flags_cohorts standard_flags_memberships standard_flags_state].freeze
      RULE_COLUMNS = %i[
        id key status hash_version salt percentage_bps rollout_value variant_weights fallthrough_value
        stop_value conditions cohorts member_count lock_version full_since last_evaluated_at updated_at
      ].freeze
      COHORT_COLUMNS = %i[id key name description unit member_count archived_at].freeze
      MEMBERSHIP_COLUMNS = %i[rule_id cohort_id unit unit_key value expires_at].freeze
      NEXT_REVISION = "nextval(pg_get_serial_sequence('standard_flags_state', 'revision'))".freeze
      BUMP_REVISION = "UPDATE standard_flags_state SET revision = #{NEXT_REVISION} RETURNING revision".freeze
      # Seeds the single row when it is missing (a database built from
      # schema.rb or structure.sql never ran the migration's insert). Runs
      # under LOCK_STATE, so two writers can't both insert one.
      SEED_STATE = "INSERT INTO standard_flags_state (revision) SELECT #{NEXT_REVISION} " \
                   "WHERE NOT EXISTS (SELECT 1 FROM standard_flags_state)".freeze
      LOCK_STATE = "LOCK TABLE standard_flags_state IN SHARE ROW EXCLUSIVE MODE".freeze
      MEMBERSHIP_INSERT_COLUMNS = %i[rule_id cohort_id unit unit_key value expires_at created_at updated_at].freeze

      # nil when standard_flags_state has no row yet: there is no revision,
      # and the cache reloads at every check until a write creates one.
      def revision
        read("revision check") { Models::State.pick(:revision) }
      end

      def load
        read("rule load") do
          Loaded.new(
            rules: Models::Rule.pluck(*RULE_COLUMNS).map { |row| Rule.build(**RULE_COLUMNS.zip(row).to_h) },
            cohorts: Models::Cohort.pluck(*COHORT_COLUMNS).map { |row| Cohort.build(**COHORT_COLUMNS.zip(row).to_h) }
          )
        end
      end

      def memberships(unit, unit_keys)
        read("membership lookup", quote: false) do
          Models::Membership.where(unit: unit.to_s, unit_key: unit_keys, removed_at: nil)
                            .pluck(*MEMBERSHIP_COLUMNS)
                            .map { |row| membership(row) }
        end
      end

      # false when a table is missing; raises (so the health check warns
      # instead of failing) when the database can't be reached.
      def ready?
        Models::Record.with_connection { |connection| TABLES.all? { |table| connection.data_source_exists?(table) } }
      rescue ::ActiveRecord::StatementInvalid => e
        raise unless e.cause&.class&.name == "PG::UndefinedTable"

        false
      end

      # With prepared statements off (common behind a transaction-mode
      # pooler), bind values are inlined into the SQL text, so unit keys reach
      # SQL logs, notification payloads and APM spans unfiltered.
      def warnings
        list = []
        unless prepared_statements?
          list << "prepared statements are off, so unit keys are inlined into membership lookup SQL " \
                  "(logs, APM spans); see the README's runtime rules privacy notes"
        end
        if state_row_missing?
          list << "standard_flags_state has no row (a database loaded from schema.rb skips the migration's " \
                  "insert); the next change creates it, and until then every check reloads the rules"
        end
        list
      end

      # One write (see Store), in a transaction, or a savepoint inside the
      # host's own transaction, so it commits or rolls back with it. Database
      # errors are re-raised as StoreError naming only the error class: a
      # driver message can quote a unit key.
      #
      # Its last statement is a `SELECT 1`. Postgres answers COMMIT on a
      # transaction that a swallowed error aborted with a silent ROLLBACK,
      # and ActiveRecord still runs after_commit callbacks; the check makes
      # that case raise here, so the write fails instead of reporting a
      # change that never committed.
      def write
        Models::Record.transaction(requires_new: true) do
          transaction = Transaction.new
          yield(transaction).tap { transaction.verify! }
        end
      rescue ::ActiveRecord::ActiveRecordError => e
        raise StoreError.new("write failed: #{e.class}", cause_class: e.class.name), cause: nil
      end

      # Locks the owners of expired memberships first (rules, then cohorts,
      # each by id, as every write does), then deletes and recounts. The
      # recount is a new statement after the locks, so it sees any
      # AddMembers that committed while purge waited.
      def purge(before:)
        guard("purge") do
          Models::Record.transaction(requires_new: true) do
            owners = expired_before(before).distinct.pluck(:rule_id, :cohort_id)
            rule_ids = Models::Rule.where(id: owners.filter_map(&:first).uniq).order(:id).lock.pluck(:id)
            cohort_ids = Models::Cohort.where(id: owners.filter_map(&:last).uniq).order(:id).lock.pluck(:id)
            removed = Models::Membership.where(removed_at: ...before).delete_all
            expired = expired_before(before).where(rule_id: rule_ids).or(expired_before(before).where(cohort_id: cohort_ids)).delete_all
            unless expired.zero?
              recount(Models::Rule, :rule_id, rule_ids)
              recount(Models::Cohort, :cohort_id, cohort_ids)
              Runtime.bump_revision!(Transaction.new)
            end
            { removed: removed, expired: expired }
          end
        end
      end

      def purgeable(before:)
        guard("purge count") do
          { removed: Models::Membership.where(removed_at: ...before).count, expired: expired_before(before).count }
        end
      end

      # One UPDATE that never waits: rows another write holds are skipped
      # (FOR UPDATE SKIP LOCKED), and it is skipped (nil) inside an open
      # transaction. The assignment is SQL, not a Hash, so ActiveRecord
      # leaves lock_version alone, and updated_at isn't touched: neither is
      # a change to the rule.
      def touch_evaluated(keys, before:)
        return nil if Models::Record.connection_pool.active_connection&.transaction_open?

        guard("evaluation tracking") do
          due = Models::Rule.where(key: keys.map(&:to_s))
                            .where("last_evaluated_at IS NULL OR last_evaluated_at < ?", before)
                            .lock("FOR UPDATE SKIP LOCKED").select(:id)
          Models::Record.with_connection do
            Models::Rule.where(id: due).update_all([ "last_evaluated_at = ?", Time.now.utc ])
          end
        end
      end

      # One write's view of the tables. Rows are locked FOR UPDATE as they
      # are read, and held until the write ends.
      #
      # Every write takes its locks in one order: the owner row (a rule or a
      # cohort), then cohorts by id (lock_cohorts, one statement), then
      # memberships, then the state row last (lock_revision, bump_revision).
      # Purge locks the rules, then the cohorts, it is about to recount, each
      # by id, before touching a membership. A write only ever waits on a
      # row later in that order than every row it holds, so two of them
      # can't wait on each other: Start and AttachCohort (rule, then its
      # cohorts) against AddMembers on a cohort (that cohort, then its
      # memberships) or on a rule (that rule, then its memberships), and
      # purge against any of them.
      class Transaction
        def initialize
          @rules = {}
          @cohorts = {}
        end

        # Raises if a swallowed error aborted the transaction (see write).
        def verify!
          Models::Record.with_connection { |connection| connection.select_value("SELECT 1") }
        end

        # Runs the block in a savepoint: an error inside it, even one the
        # block swallowed, rolls back only the savepoint and is raised here.
        def isolated(&)
          Models::Record.transaction(requires_new: true, &)
        end

        # Runs the block once the write commits: at the end of `write`, or
        # when the host's own transaction commits. Never when it rolls back.
        def after_commit(&)
          Models::Record.current_transaction.after_commit(&)
        end

        def lock_rule(key)
          record = Models::Rule.lock.find_by(key: key.to_s)
          record && rule(@rules[record.key] = record)
        end

        # ON CONFLICT DO NOTHING, then the locking read: two writers creating
        # the same rule end up holding the one row in turn.
        def create_rule(key, salt:, hash_version:)
          Models::Rule.insert_all([ { key: key.to_s, salt: salt, hash_version: hash_version, status: "draft" } ], unique_by: :key)
          lock_rule(key)
        end

        # lock_version is ActiveRecord's optimistic-locking column, so
        # update! moves it on by one.
        def save_rule(rule, attributes)
          record = @rules.fetch(rule.key.to_s)
          record.update!(attributes.merge(updated_at: Time.now.utc))
          rule(record)
        end

        def lock_cohort(key)
          record = Models::Cohort.lock.find_by(key: key.to_s)
          record && cohort(@cohorts[record.key] = record)
        end

        # One statement, locking in id order.
        def lock_cohorts(keys)
          return {} if keys.empty?

          Models::Cohort.where(key: keys.map(&:to_s).uniq).order(:id).lock.to_a.to_h do |record|
            [ record.key, cohort(@cohorts[record.key] = record) ]
          end
        end

        # nil when the key was taken, by an earlier cohort or a writer that
        # committed it while this one waited on the unique index.
        def create_cohort(key, unit:, name: nil, description: nil)
          inserted = Models::Cohort.insert_all([ { key: key.to_s, unit: unit.to_s, name: name, description: description } ],
                                               unique_by: :key, returning: :id)
          lock_cohort(key) unless inserted.rows.empty?
        end

        def save_cohort(cohort, attributes)
          record = @cohorts.fetch(cohort.key)
          record.update!(attributes.merge(updated_at: Time.now.utc))
          cohort(record)
        end

        def rules_attached_to(cohort_key)
          Models::Rule.where("cohorts @> ?", [ { cohort: cohort_key.to_s } ].to_json).order(:key).pluck(:key).map(&:to_sym)
        end

        def upsert_members(owner, unit:, unit_keys:, value:, expires_at:)
          live = members_of(owner).where(unit: unit.to_s, unit_key: unit_keys)
          existing = live.pluck(:unit_key)
          now = Time.now.utc
          live.update_all(value: value, expires_at: expires_at, updated_at: now) unless existing.empty?
          fresh = unit_keys - existing
          insert_members(owner, fresh, unit: unit.to_s, value: value, expires_at: expires_at, now: now) unless fresh.empty?
          recount(owner)
          { added: fresh.size, updated: existing.size }
        end

        def remove_members(owner, unit:, unit_keys:)
          now = Time.now.utc
          removed = members_of(owner).where(unit: unit.to_s, unit_key: unit_keys).update_all(removed_at: now, updated_at: now)
          recount(owner) unless removed.zero?
          removed
        end

        def count_members(owner, now: nil)
          scope = members_of(owner)
          scope = scope.where("expires_at IS NULL OR expires_at > ?", now) if now
          scope.count
        end

        # Creates the state row first when it is missing.
        def lock_revision
          locked = Models::State.lock.pick(:revision)
          return locked unless locked.nil?

          seed_state
          Models::State.lock.pick(:revision)
        end

        # The next value of the revision column's own sequence, never
        # revision + 1: a number taken by a write that rolls back is never
        # reused, so a process that saw the uncommitted rules under it
        # reloads at its next check. Creates the state row first when it is
        # missing, so a write never "succeeds" without moving the revision.
        def bump_revision
          seed_state unless Models::State.exists?
          bumped = Models::Record.with_connection { |connection| connection.select_value(BUMP_REVISION) }
          raise StoreError, "revision bump failed: standard_flags_state has no row" if bumped.nil?

          Integer(bumped)
        end

        private

        # Under a table lock (held to the end of the write, and taken only
        # when the row is missing), so concurrent writers insert one row.
        # Callers check for the row with a plain read first and take the lock
        # before any UPDATE of the table: a writer holding the UPDATE's lock
        # while waiting for this one would deadlock with another doing the
        # same.
        def seed_state
          Models::Record.with_connection do |connection|
            connection.execute(LOCK_STATE)
            connection.execute(SEED_STATE)
          end
        end

        # One INSERT with every value bound, never inlined: unit keys can be
        # phone numbers or emails, and SQL text reaches logs, notification
        # payloads and APM spans. The binds are named `unit_key` and so on,
        # so log filtering applies to them (Runtime.filter_unit_keys!). Not
        # prepared: each key count would be a new statement.
        def insert_members(owner, unit_keys, unit:, value:, expires_at:, now:)
          ids = owner.is_a?(Runtime::Rule) ? [ owner.id, nil ] : [ nil, owner.id ]
          width = MEMBERSHIP_INSERT_COLUMNS.size
          rows = unit_keys.each_index.map { |row| "(#{Array.new(width) { |i| "$#{(row * width) + i + 1}" }.join(', ')})" }
          binds = unit_keys.flat_map do |unit_key|
            MEMBERSHIP_INSERT_COLUMNS.zip([ *ids, unit, unit_key, value, expires_at, now, now ]).map do |column, bound|
              ::ActiveRecord::Relation::QueryAttribute.new(column.to_s, bound, Models::Membership.type_for_attribute(column))
            end
          end
          sql = "INSERT INTO standard_flags_memberships (#{MEMBERSHIP_INSERT_COLUMNS.join(', ')}) " \
                "VALUES #{rows.join(', ')} ON CONFLICT DO NOTHING"
          Models::Record.with_connection { |connection| connection.exec_query(sql, "StandardFlags membership insert", binds, prepare: false) }
        end

        def members_of(owner)
          Models::Membership.where(owner_column(owner) => owner.id, removed_at: nil)
        end

        def owner_column(owner)
          owner.is_a?(Runtime::Rule) ? :rule_id : :cohort_id
        end

        # member_count counts memberships not removed, expired or not.
        def recount(owner)
          count = members_of(owner).count
          (owner.is_a?(Runtime::Rule) ? @rules.fetch(owner.key.to_s) : @cohorts.fetch(owner.key)).update_columns(member_count: count)
        end

        def rule(record)
          Runtime::Rule.build(**RULE_COLUMNS.to_h { |column| [ column, record.public_send(column) ] })
        end

        def cohort(record)
          Runtime::Cohort.build(**COHORT_COLUMNS.to_h { |column| [ column, record.public_send(column) ] })
        end
      end

      private

      def expired_before(before)
        Models::Membership.where(removed_at: nil).where(expires_at: ...before)
      end

      def recount(model, column, ids)
        return if ids.empty?

        owner = Models::Membership.arel_table[column].eq(model.arel_table[:id])
        count = Models::Membership.where(removed_at: nil).where(owner).select(Arel.star.count).to_sql
        model.where(id: ids.uniq).update_all("member_count = (#{count})")
      end

      def guard(what)
        yield
      rescue StandardError => e
        raise StoreError.new("#{what} failed: #{e.class}", cause_class: e.class.name), cause: nil
      end

      def state_row_missing?
        Models::Record.with_connection { |connection| connection.data_source_exists?("standard_flags_state") } &&
          !Models::State.exists?
      rescue StandardError
        false
      end

      def prepared_statements?
        value = Models::Record.connection_db_config.configuration_hash.fetch(:prepared_statements, true)
        ::ActiveRecord::Type::Boolean.new.cast(value) != false
      end

      def membership(row)
        attributes = MEMBERSHIP_COLUMNS.zip(row).to_h
        Membership.new(**attributes, unit: attributes[:unit].to_sym)
      end

      def read(what, quote: true, &)
        connection = Models::Record.connection_pool.active_connection
        connection&.transaction_open? ? Models::Record.transaction(requires_new: true, &) : yield
      rescue StandardError => e
        message = quote ? "#{what} failed: #{e.class}: #{e.message}" : "#{what} failed: #{e.class}"
        raise StoreError.new(message, cause_class: e.class.name), cause: nil
      end
    end
  end
end
