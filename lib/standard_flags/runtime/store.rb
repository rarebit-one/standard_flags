module StandardFlags
  module Runtime
    # Raised by a store when it can't read. The message names the failing
    # read and the underlying error class, never a unit key.
    class StoreError < StandardFlags::Error
      # The class name of the error underneath, which is deliberately not
      # kept as `cause` (a driver message can quote a unit key).
      attr_reader :cause_class

      def initialize(message, cause_class: nil)
        super(message)
        @cause_class = cause_class
      end
    end

    # Where runtime rules come from. The read path calls four methods:
    #
    # * revision                     — the current standard_flags_state
    #                                  revision (Integer).
    # * load                         — a Loaded with every rule and cohort.
    #                                  The cache calls it after `revision`.
    # * memberships(unit, unit_keys) — live (not removed) memberships for
    #                                  those keys of one unit, across every
    #                                  rule and cohort, in one read.
    # * ready?                       — whether the tables exist, for the
    #                                  health check.
    #
    # Implementations: ActiveRecordStore (the default when runtime rules are
    # on) and MemoryStore (specs, and apps without a database).
    class Store
      def revision
        raise NotImplementedError, "#{self.class} must implement revision"
      end

      def load
        raise NotImplementedError, "#{self.class} must implement load"
      end

      def memberships(_unit, _unit_keys)
        raise NotImplementedError, "#{self.class} must implement memberships"
      end

      def ready?
        true
      end
    end
  end
end
