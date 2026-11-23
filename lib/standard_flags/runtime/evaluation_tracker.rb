require "set"

module StandardFlags
  module Runtime
    # Write-behind for standard_flags_rules.last_evaluated_at, which
    # `flags:stale` reads to find rules nothing evaluates any more.
    #
    # Evaluating a flag that has a rule only adds its key to an in-memory
    # set. Nothing is written during an evaluation. The write happens when a
    # unit of work ends (the executor's `complete` hook, Memo::Hook, after
    # the request or job has done its work), at most once per
    # `config.evaluation_tracking_interval` (default an hour) per process,
    # as one UPDATE of the rows not already marked within the interval. It
    # never waits: rows a write holds are skipped, and so is the whole flush
    # inside an open transaction (the keys wait for the next one). It is
    # best-effort: a failed write is reported once and the keys are kept for
    # the next try. `config.track_evaluations = false` turns it off.
    #
    # Fork-safe without a reset: a child keeps the keys it inherited and
    # flushes them itself. The lock is never replaced (see Cache); Ruby
    # releases a mutex held by a thread that doesn't survive the fork.
    class EvaluationTracker
      # Set while operator reads evaluate (see #untracked).
      UNTRACKED = :standard_flags_untracked

      def initialize
        @mutex = Mutex.new
        @keys = Set.new
        @flushed_at = nil
      end

      # Whether evaluations on this thread or fiber are left untracked.
      def self.untracked?
        Thread.current[UNTRACKED] ? true : false
      end

      def track(key)
        return unless StandardFlags.config.track_evaluations

        @mutex.synchronize { @keys << key }
      end

      # Called by Runtime.unit_of_work_complete! with its monotonic clock.
      # The interval is checked and claimed under the lock, so threads that
      # end their units of work together flush once. Never raises.
      def flush(store, now)
        config = StandardFlags.config
        return unless config.track_evaluations

        interval = config.evaluation_tracking_interval.to_f
        keys = @mutex.synchronize do
          next if @keys.empty? || (@flushed_at && now - @flushed_at < interval)

          @flushed_at = now
          @keys.to_a
        end
        return unless keys

        if store.touch_evaluated(keys, before: Time.now.utc - interval).nil?
          @mutex.synchronize { @flushed_at = nil }
        else
          @mutex.synchronize { @keys.subtract(keys) }
        end
      rescue StandardError => e
        failed(e)
      end

      # Evaluations inside the block (on this thread or fiber) are not
      # tracked. Operator reads (the MCP tools, the admin page built on
      # them) evaluate every flag they show, which is not the app using it,
      # so they must not hide a dead flag from `flags:stale`.
      def untracked
        previous = Thread.current[UNTRACKED]
        Thread.current[UNTRACKED] = true
        yield
      ensure
        Thread.current[UNTRACKED] = previous
      end

      def pending
        @mutex.synchronize { @keys.to_a.sort }
      end

      private

      def failed(error)
        name = (error.cause_class if error.is_a?(StoreError)) || error.class.name
        Reporting.once(:evaluation_tracking, name) { Reporting.report(error, runtime: "evaluation_tracking") }
        Reporting.instrument(:evaluation_tracking_failed, error_class: name)
      end
    end
  end
end
