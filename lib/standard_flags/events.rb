module StandardFlags
  # The events the write path publishes, one per operation, through
  # ActiveSupport::Notifications. Their payload carries the actor (a record,
  # or nil for a system actor), `actor_label`, `reason`, the flag `key` or
  # `cohort`, `revision` (a rule's lock_version, or for cohorts the store's
  # revision) and `store_revision`, and the rule or cohort state `before`
  # and `after`. Membership changes carry `unit`, `value` and counts, never
  # a unit key.
  module Events
    NAMESPACE = "standard_flags".freeze

    FLAG = %w[started paused stopped ramped variants_set value_set conditions_set members_added members_removed restored].freeze
    COHORT = %w[created archived attached detached members_added members_removed restored].freeze

    FLAG_EVENTS = FLAG.to_h { |verb| [ verb.to_sym, "#{NAMESPACE}.flag.#{verb}".freeze ] }.freeze
    # Membership changes on a cohort publish `standard_flags.cohort.members_*`.
    COHORT_EVENTS = COHORT.to_h { |verb| [ verb.to_sym, "#{NAMESPACE}.cohort.#{verb}".freeze ] }.freeze

    # Operator reads that show what only a reveal may (not changes): unit
    # keys revealed by list_members, and get_flag evaluated for one unit key
    # (which says whether it is a member). Counts only, never a key.
    MEMBERS_REVEALED = "#{NAMESPACE}.members.revealed".freeze
    FLAG_PROBED = "#{NAMESPACE}.flag.probed".freeze
    READS = [ MEMBERS_REVEALED, FLAG_PROBED ].freeze

    # Every event an audit log should keep: all of them.
    AUDITABLE = (FLAG_EVENTS.values + COHORT_EVENTS.values + READS).freeze

    class << self
      # The event names a host should persist to its audit log, as full
      # Strings that ActiveSupport::Notifications and standard_audit's
      # `subscribe_to` both accept:
      #
      #   StandardAudit.configure do |config|
      #     StandardFlags::Events.auditable.each { |pattern| config.subscribe_to(pattern) }
      #   end
      #
      # When standard_audit subscribes to an event, operations leave the row
      # to its subscriber (which runs inside the operation's transaction);
      # otherwise they write it themselves. Either way there is one row per
      # change. New releases may add to the list.
      #
      # @return [Array<String>] frozen
      def auditable
        AUDITABLE
      end
    end
  end
end
