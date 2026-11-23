module StandardFlags
  module Runtime
    # Holds the process-wide RuleSnapshot and refreshes it lazily, on
    # evaluation: once `interval` seconds have passed it reads the store's
    # revision (one query) and reloads only when the revision has moved.
    #
    # No background thread is started, so it is fork-safe: after a fork the
    # child keeps the inherited snapshot. The lock is never replaced; Ruby
    # releases a mutex held by a thread that doesn't survive the fork, and
    # the forking thread can't be mid-refresh.
    #
    # If the store errors, the last good snapshot keeps serving, marked
    # stale; the error is reported once per class and `runtime_stale` is
    # emitted. The next attempt waits a full interval, so a database outage
    # costs one failed query per interval, not one per evaluation. A process
    # that has never loaded serves an empty, unloaded snapshot, and every
    # flag falls back to its code default.
    #
    # A refresh only reads. A store with no revision yet (nil) never counts
    # as unchanged, so the rules reload at every check until a write
    # creates one.
    class Cache
      attr_reader :store

      def initialize(store, interval: nil, clock: nil)
        @store = store
        @interval = interval
        @clock = clock
        @snapshot = nil
        @mutex = Mutex.new
      end

      # The current snapshot, refreshed first if it is due. Never raises.
      def snapshot
        current = @snapshot
        return current if fresh?(current)

        if current
          return current unless @mutex.try_lock # another thread is refreshing
        else
          @mutex.lock
        end
        begin
          current = @snapshot
          fresh?(current) ? current : (@snapshot = refresh(current))
        ensure
          @mutex.unlock
        end
      end

      # The snapshot as it stands, without refreshing (for diagnostics).
      def peek
        @snapshot
      end

      # Makes the next read check the revision, whatever the interval. The
      # write path calls it, so the writing process sees its own change.
      def expire!
        current = @snapshot
        @snapshot = current.with(checked_at: nil) if current
      end

      private

      def fresh?(snapshot)
        snapshot && snapshot.checked_at && now - snapshot.checked_at < interval
      end

      def refresh(current)
        checked_at = now
        revision = store.revision
        return current.with(checked_at: checked_at, stale: false) if current&.loaded && !revision.nil? && current.revision == revision

        snapshot = RuleSnapshot.build(store.load, revision: revision, checked_at: checked_at)
        Reporting.instrument(:runtime_refresh, revision: snapshot.revision, rules: snapshot.rules.size)
        snapshot
      rescue StandardError => e
        failed(current || RuleSnapshot.empty, checked_at, e)
      end

      def failed(current, checked_at, error)
        name = (error.cause_class if error.is_a?(StoreError)) || error.class.name
        Reporting.once(:runtime_store, name) { Reporting.report(error, runtime: "refresh") }
        Reporting.instrument(:runtime_stale,
          error_class: name, revision: current.revision, loaded: current.loaded, age: current.age)
        current.with(checked_at: checked_at, stale: true)
      end

      def interval
        (@interval || StandardFlags.config.refresh_interval).to_f
      end

      def now
        @clock ? @clock.call : Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
