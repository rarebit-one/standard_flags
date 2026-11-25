require "monitor"

module StandardFlags
  module Runtime
    # An in-process store, for specs and for apps without a database. Every
    # write bumps the revision, so the cache picks it up at its next check.
    # Thread-safe. `reads` counts calls per method, so specs can assert what
    # evaluation cost without a database.
    #
    #   store = StandardFlags::Runtime::MemoryStore.new
    #   store.put_rule(:new_checkout, status: :running, percentage_bps: 500)
    #   store.put_cohort(:staff, unit: :account)
    #   store.add_member(cohort: :staff, unit: :account, unit_key: "42", value: true)
    #   StandardFlags.configure { |c| c.runtime_rules = true; c.runtime_store = store }
    #
    # Values may be given as Ruby values (true, false, :sensor) or as their
    # stored strings ("on", "off", "sensor").
    #
    # It also takes the write path (StandardFlags::Operations): `write` holds
    # the store's lock for the whole block and restores the previous state
    # if the block raises; after_commit blocks run once it returns, outside
    # the lock. Removed memberships are kept, as in the database, until
    # `purge`.
    class MemoryStore < Store
      RULE_ATTRIBUTES = %i[
        status hash_version salt percentage_bps rollout_value variant_weights
        fallthrough_value stop_value conditions cohorts full_since last_evaluated_at updated_at
      ].freeze
      # A removed membership and when it was removed.
      Removed = Data.define(:membership, :removed_at)

      attr_reader :reads

      def initialize
        # Reentrant, so an event subscriber that evaluates a flag during a
        # write can read the store.
        @mutex = Monitor.new
        @revision = 0
        @sequence = 0 # like a database sequence: never rolled back
        @next_id = 0
        @rules = {}
        @cohorts = {}
        @memberships = []
        @removed = []
        @reads = Hash.new(0)
        @pending = nil # after_commit blocks of the write in progress
        @compat = {}
      end

      def revision
        @mutex.synchronize do
          @reads[:revision] += 1
          @revision
        end
      end

      def load
        @mutex.synchronize do
          @reads[:load] += 1
          Loaded.new(rules: @rules.values, cohorts: @cohorts.values)
        end
      end

      def memberships(unit, unit_keys)
        unit = unit.to_sym
        keys = unit_keys.map(&:to_s)
        @mutex.synchronize do
          @reads[:memberships] += 1
          @memberships.select { |m| m.unit == unit && keys.include?(m.unit_key) }
        end
      end

      # The stored rule for `key`, or nil. Not counted in `reads`.
      def rule(key)
        @mutex.synchronize { @rules[key.to_sym] }
      end

      # Creates or replaces the rule for `key`. Unset attributes keep their
      # current value; the salt defaults to the key.
      def put_rule(key, **attributes)
        unknown = attributes.keys - RULE_ATTRIBUTES
        raise ArgumentError, "unknown rule attribute(s): #{unknown.join(', ')}" unless unknown.empty?

        key = key.to_sym
        mutate do
          current = @rules[key]&.to_h || { id: next_id, key: key, salt: key.to_s }
          rule = Rule.build(**current.merge(normalize_rule(attributes), member_count: count_members(rule_id: current[:id])))
          raise ArgumentError, "status must be one of #{Values::STATUSES.join('/')}" unless Values::STATUSES.include?(rule.status)

          @rules[key] = rule
        end
      end

      def put_cohort(key, unit:, name: nil, archived_at: nil)
        key = key.to_s
        mutate do
          id = @cohorts[key]&.id || next_id
          @cohorts[key] = Cohort.build(id: id, key: key, name: name, unit: unit, archived_at: archived_at,
                                       member_count: count_members(cohort_id: id))
        end
      end

      # Adds (or replaces) one membership on a rule or a cohort.
      def add_member(unit:, unit_key:, value:, rule: nil, cohort: nil, expires_at: nil, created_at: Time.now)
        mutate do
          rule_id, cohort_id = owner_ids(rule, cohort)
          unit = unit.to_sym
          unit_key = unit_key.to_s
          @memberships.reject! { |m| m.rule_id == rule_id && m.cohort_id == cohort_id && m.unit == unit && m.unit_key == unit_key }
          @memberships << Membership.new(rule_id: rule_id, cohort_id: cohort_id, unit: unit, unit_key: unit_key,
                                         value: Runtime.wire(value), expires_at: expires_at, created_at: created_at)
          recount(rule_id, cohort_id)
        end
      end

      def remove_member(unit:, unit_key:, rule: nil, cohort: nil)
        mutate do
          rule_id, cohort_id = owner_ids(rule, cohort)
          @memberships.reject! do |m|
            m.rule_id == rule_id && m.cohort_id == cohort_id && m.unit == unit.to_sym && m.unit_key == unit_key.to_s
          end
          recount(rule_id, cohort_id)
        end
      end

      # Runs the block as one write (see Store). Other threads wait until it
      # ends.
      def write
        committed = nil
        value = @mutex.synchronize do
          outermost = @pending.nil?
          @pending ||= []
          begin
            isolate { yield Transaction.new(self) }.tap { committed = @pending if outermost }
          ensure
            @pending = nil if outermost
          end
        end
        committed&.each(&:call)
        value
      end

      def purge(before:)
        @mutex.synchronize do
          removed = @removed.count { |entry| entry.removed_at < before }
          @removed.reject! { |entry| entry.removed_at < before }
          expired, @memberships = @memberships.partition { |m| expired_before?(m, before) }
          expired.map { |m| [ m.rule_id, m.cohort_id ] }.uniq.each { |ids| recount(*ids) }
          next_revision! unless expired.empty?
          { removed: removed, expired: expired.size }
        end
      end

      def purgeable(before:)
        @mutex.synchronize do
          { removed: @removed.count { |entry| entry.removed_at < before },
            expired: @memberships.count { |m| expired_before?(m, before) } }
        end
      end

      # Counted in `reads`, so specs can assert how often it ran.
      def touch_evaluated(keys, before:)
        now = Time.now
        @mutex.synchronize do
          @reads[:touch_evaluated] += 1
          keys.map(&:to_sym).count do |key|
            rule = @rules[key]
            next false unless rule && (rule.last_evaluated_at.nil? || rule.last_evaluated_at < before)

            @rules[key] = rule.with(last_evaluated_at: now)
          end
        end
      end

      def record_compat(stats)
        @mutex.synchronize do
          @reads[:record_compat] += 1
          now = Time.now.utc
          stats.each do |stat|
            id = [ stat.key.to_s, stat.platform ]
            @compat[id] = CompatStats.merge(@compat[id], stat, now: now)
          end
          stats.size
        end
      end

      def compat_stats(keys = nil)
        @mutex.synchronize do
          @reads[:compat_stats] += 1
          @compat.values.select { |stat| keys.nil? || keys.include?(stat.key) }.sort_by { |stat| [ stat.key, stat.platform ] }
        end
      end

      def members(rule: nil, cohort: nil, offset: 0, limit: nil)
        @mutex.synchronize do
          ids = owner_ids_or_nil(rule, cohort)
          next MemberPage.new(memberships: [], total: 0) unless ids

          live = @memberships.select { |m| [ m.rule_id, m.cohort_id ] == ids }
          page = limit ? live.drop(offset).first(limit) : live.drop(offset)
          MemberPage.new(memberships: page, total: live.size)
        end
      end

      def members_at(at, rule: nil, cohort: nil)
        @mutex.synchronize do
          ids = owner_ids_or_nil(rule, cohort)
          next [] unless ids

          live = @memberships.select { |m| [ m.rule_id, m.cohort_id ] == ids && existed_at?(m, at) }
          gone = @removed.select do |entry|
            [ entry.membership.rule_id, entry.membership.cohort_id ] == ids && entry.removed_at > at && existed_at?(entry.membership, at)
          end
          live + gone.map(&:membership)
        end
      end

      # Removed memberships, for specs. Not counted in `reads`.
      def removed_memberships
        @mutex.synchronize { @removed.map(&:membership) }
      end

      # One write. Methods are documented on Store.
      class Transaction
        def initialize(store)
          @store = store
        end

        %i[lock_rule create_rule save_rule lock_cohort lock_cohorts create_cohort save_cohort rules_attached_to
           upsert_members remove_members count_members lock_revision bump_revision].each do |name|
          define_method(name) { |*args, **kwargs| @store.__send__(:"tx_#{name}", *args, **kwargs) }
        end

        def isolated(&)
          @store.__send__(:isolate, &)
        end

        def after_commit(&block)
          @store.__send__(:tx_after_commit, block)
        end
      end

      private

      # Restores the state (and drops after_commit blocks) the block added
      # if it raises.
      def isolate
        saved = [ @rules.dup, @cohorts.dup, @memberships.dup, @removed.dup, @revision, @next_id, @pending.size ]
        yield
      rescue Exception # rubocop:disable Lint/RescueException -- any raise rolls the block back, then re-raises
        @rules, @cohorts, @memberships, @removed, @revision, @next_id, pending = saved
        @pending.slice!(pending..)
        raise
      end

      def mutate
        @mutex.synchronize do
          result = yield
          next_revision!
          result
        end
      end

      def tx_lock_rule(key)
        @rules[key.to_sym]
      end

      def tx_create_rule(key, salt:, hash_version:)
        key = key.to_sym
        @rules[key] ||= Rule.build(id: next_id, key: key, salt: salt, hash_version: hash_version, updated_at: Time.now)
      end

      def tx_save_rule(rule, attributes)
        current = @rules.fetch(rule.key)
        @rules[rule.key] = Rule.build(**current.to_h, **attributes, lock_version: current.lock_version + 1, updated_at: Time.now)
      end

      def tx_lock_cohort(key)
        @cohorts[key.to_s]
      end

      def tx_lock_cohorts(keys)
        keys.map(&:to_s).uniq.filter_map { |key| @cohorts[key] }.sort_by(&:id).to_h { |cohort| [ cohort.key, cohort ] }
      end

      def tx_create_cohort(key, unit:, name: nil, description: nil)
        key = key.to_s
        return if @cohorts.key?(key)

        @cohorts[key] = Cohort.build(id: next_id, key: key, unit: unit, name: name, description: description)
      end

      def tx_after_commit(block)
        @pending << block
      end

      def tx_save_cohort(cohort, attributes)
        @cohorts[cohort.key] = Cohort.build(**@cohorts.fetch(cohort.key).to_h, **attributes)
      end

      def tx_rules_attached_to(cohort_key)
        @rules.values.select { |rule| rule.cohort_attachments.any? { |key, _| key == cohort_key.to_s } }.map(&:key).sort
      end

      def tx_upsert_members(owner, unit:, unit_keys:, value:, expires_at:)
        rule_id, cohort_id = owner_of(owner)
        unit = unit.to_sym
        counts = { added: 0, updated: 0 }
        now = Time.now
        unit_keys.each do |unit_key|
          existing = @memberships.index { |m| m.rule_id == rule_id && m.cohort_id == cohort_id && m.unit == unit && m.unit_key == unit_key }
          counts[existing ? :updated : :added] += 1
          if existing
            current = @memberships[existing]
            next if current.value == value && current.expires_at == expires_at

            # Versioned, as in the database: the old one is kept as removed.
            @removed << Removed.new(membership: @memberships.delete_at(existing), removed_at: now)
          end
          @memberships << Membership.new(rule_id: rule_id, cohort_id: cohort_id, unit: unit, unit_key: unit_key,
                                         value: value, expires_at: expires_at, created_at: now)
        end
        recount(rule_id, cohort_id)
        counts
      end

      def tx_remove_members(owner, unit:, unit_keys:)
        rule_id, cohort_id = owner_of(owner)
        now = Time.now
        gone, @memberships = @memberships.partition do |m|
          m.rule_id == rule_id && m.cohort_id == cohort_id && m.unit == unit.to_sym && unit_keys.include?(m.unit_key)
        end
        @removed.concat(gone.map { |m| Removed.new(membership: m, removed_at: now) })
        recount(rule_id, cohort_id)
        gone.size
      end

      def tx_count_members(owner, now: nil)
        rule_id, cohort_id = owner_of(owner)
        @memberships.count { |m| m.rule_id == rule_id && m.cohort_id == cohort_id && (now.nil? || m.live?(now)) }
      end

      def tx_lock_revision
        @revision
      end

      def tx_bump_revision
        next_revision!
      end

      # A rolled-back write restores @revision but not @sequence, so its
      # number is never handed out again.
      def next_revision!
        @revision = (@sequence += 1)
      end

      def owner_of(owner)
        owner.is_a?(Rule) ? [ owner.id, nil ] : [ nil, owner.id ]
      end

      def expired_before?(membership, before)
        !membership.expires_at.nil? && membership.expires_at < before
      end

      def next_id
        @next_id += 1
      end

      def normalize_rule(attributes)
        attributes.to_h do |name, value|
          value =
            case name
            when :status then value.to_s
            when :rollout_value, :fallthrough_value, :stop_value then Runtime.wire(value)
            when :variant_weights then value.to_h { |variant, weight| [ Runtime.wire(variant), weight ] }
            when :cohorts then normalize_attachments(value)
            else value
            end
          [ name, value ]
        end
      end

      # `{ staff: true }` or `[{ cohort: :staff, value: true }]`, in order.
      def normalize_attachments(value)
        pairs = value.is_a?(Hash) ? value.to_a : Array(value).map { |a| a.to_h.transform_keys(&:to_s).values_at("cohort", "value") }
        pairs.map { |cohort, served| { "cohort" => cohort.to_s, "value" => Runtime.wire(served) } }
      end

      # Like owner_ids, but nil for an owner that doesn't exist.
      def owner_ids_or_nil(rule, cohort)
        raise ArgumentError, "pass exactly one of rule: or cohort:" unless rule.nil? ^ cohort.nil?

        rule ? (id = @rules[rule.to_sym]&.id) && [ id, nil ] : (id = @cohorts[cohort.to_s]&.id) && [ nil, id ]
      end

      # Created by `at`, and not expired by then.
      def existed_at?(membership, at)
        (membership.created_at.nil? || membership.created_at <= at) && (membership.expires_at.nil? || membership.expires_at > at)
      end

      def owner_ids(rule, cohort)
        raise ArgumentError, "pass exactly one of rule: or cohort:" unless rule.nil? ^ cohort.nil?

        if rule
          [ @rules.fetch(rule.to_sym) { raise ArgumentError, "no rule for :#{rule}; put_rule first" }.id, nil ]
        else
          [ nil, @cohorts.fetch(cohort.to_s) { raise ArgumentError, "no cohort #{cohort.inspect}; put_cohort first" }.id ]
        end
      end

      def count_members(rule_id: nil, cohort_id: nil)
        return 0 if rule_id.nil? && cohort_id.nil?

        @memberships.count { |m| rule_id ? m.rule_id == rule_id : m.cohort_id == cohort_id }
      end

      def recount(rule_id, cohort_id)
        if rule_id
          key, rule = @rules.find { |_, r| r.id == rule_id }
          @rules[key] = rule.with(member_count: count_members(rule_id: rule_id))
        else
          key, cohort = @cohorts.find { |_, c| c.id == cohort_id }
          @cohorts[key] = cohort.with(member_count: count_members(cohort_id: cohort_id))
        end
      end
    end
  end
end
