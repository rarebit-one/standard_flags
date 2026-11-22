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
        stop_value conditions cohorts member_count lock_version updated_at
      ].freeze
      COHORT_COLUMNS = %i[id key name unit member_count archived_at].freeze
      MEMBERSHIP_COLUMNS = %i[rule_id cohort_id unit unit_key value expires_at].freeze

      def revision
        read("revision check") { Models::State.pick(:revision) || 0 }
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

      def ready?
        Models::Record.with_connection { |connection| TABLES.all? { |table| connection.data_source_exists?(table) } }
      end

      private

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
