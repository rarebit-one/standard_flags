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
    #                                  revision (Integer), or nil when there
    #                                  is none yet; the cache then reloads at
    #                                  every check.
    # * load                         — a Loaded with every rule and cohort.
    #                                  The cache calls it after `revision`.
    # * memberships(unit, unit_keys) — live (not removed) memberships for
    #                                  those keys of one unit, across every
    #                                  rule and cohort, in one read.
    # * ready?                       — whether the tables exist, for the
    #                                  health check. Return false when they
    #                                  are missing; raise when the store
    #                                  can't be reached, so the check can
    #                                  tell the two apart.
    #
    # Optionally, `warnings` returns strings for the health check (a
    # configuration that exposes unit keys, say).
    #
    # The write path (StandardFlags::Operations) calls `write`, which runs
    # its block in one transaction and yields a store-specific transaction
    # object with these methods. Anything the block raises rolls the whole
    # write back, and `write` must raise rather than return when the write
    # did not commit.
    #
    # * isolated { }                — runs the block in a savepoint; an error
    #                                 in it rolls back only the block, and is
    #                                 raised from here.
    # * after_commit { }            — runs the block once the write has
    #                                 committed (with the host's transaction,
    #                                 inside one), never after a rollback.
    # * lock_rule(key)              — the Rule for `key`, locked until the
    #                                 write ends, or nil.
    # * create_rule(key, salt:, hash_version:)
    #                               — creates a draft rule (or, if another
    #                                 writer just did, returns theirs), locked.
    # * save_rule(rule, attributes) — updates the rule and returns it, with
    #                                 lock_version moved on by one.
    # * lock_cohort(key) / create_cohort(key, unit:, name:, description:) /
    #   save_cohort(cohort, attributes)
    #                               — the same for cohorts, except that
    #                                 create_cohort returns nil when the key
    #                                 is taken, even by a concurrent writer.
    # * lock_cohorts(keys)          — `{ key => Cohort }` for those that
    #                                 exist, locked in id order.
    # * rules_attached_to(cohort_key) — keys of rules that attach a cohort.
    # * upsert_members(owner, unit:, unit_keys:, value:, expires_at:)
    #                               — adds live memberships to a Rule or
    #                                 Cohort, or updates the value and expiry
    #                                 of live ones; returns { added:, updated: }.
    # * remove_members(owner, unit:, unit_keys:)
    #                               — sets removed_at on live ones; returns
    #                                 the number removed.
    # * count_members(owner, now: nil) — memberships not removed (and, with
    #                                 `now`, not expired).
    # * lock_revision / bump_revision — the state revision, locked; then
    #                                 moved to a number never used before (a
    #                                 sequence, so a rolled-back write's
    #                                 number is not reused) and returned.
    #                                 Both create the state row if it is
    #                                 missing. Call bump_revision through
    #                                 Runtime.bump_revision!.
    #
    # Maintenance, outside a write:
    #
    # * purge(before:)              — hard-deletes memberships removed or
    #                                 expired before `before`; returns counts.
    # * purgeable(before:)          — the same counts, deleting nothing.
    # * touch_evaluated(keys, before:)
    #                               — sets last_evaluated_at on those rules
    #                                 where it is unset or older than `before`,
    #                                 in one statement that never waits on a
    #                                 lock and changes nothing else on the
    #                                 rule; nil when it didn't run (and should
    #                                 be tried again).
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

      def write
        raise StoreError, "#{self.class} does not support writes"
      end

      def purge(before:) # rubocop:disable Lint/UnusedMethodArgument
        raise StoreError, "#{self.class} does not support purge"
      end

      def purgeable(before:) # rubocop:disable Lint/UnusedMethodArgument
        raise StoreError, "#{self.class} does not support purge"
      end

      # nil means "not done": a store that doesn't track evaluations.
      def touch_evaluated(_keys, before:) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      def warnings
        []
      end
    end
  end
end
