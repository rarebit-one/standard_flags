require "active_support/isolated_execution_state"

module StandardFlags
  # Per-unit-of-work memoisation.
  #
  # The store lives in ActiveSupport::IsolatedExecutionState and is opened and
  # closed by an executor hook (see Engine), not by Rack middleware, so jobs,
  # mailers, Action Cable and the console's `reload!` boundaries get the same
  # treatment as requests. Outside an executor run nothing is memoised, which
  # is what keeps ENV re-read in long-lived processes and between specs.
  module Memo
    KEY = :standard_flags_memo

    # Registered with `app.executor.register_hook`. `complete` also runs
    # the runtime rules' end-of-work step (Runtime.unit_of_work_complete!),
    # which writes last_evaluated_at when it is due.
    module Hook
      def self.run
        Memo.start!
        nil
      end

      def self.complete(_state)
        Memo.stop!
        Runtime.unit_of_work_complete!
      end
    end

    class << self
      def start!
        ActiveSupport::IsolatedExecutionState[KEY] = {}
      end

      def stop!
        ActiveSupport::IsolatedExecutionState.delete(KEY)
      end

      def active?
        !store.nil?
      end

      def clear!
        store&.clear
      end

      def fetch(key)
        memo = store
        return yield unless memo

        memo.fetch(key) { memo[key] = yield }
      end

      def key?(key)
        store&.key?(key) || false
      end

      # Stores `value` under `key` when a unit of work is open; a no-op
      # otherwise. Used to preload many entries with one query.
      def write(key, value)
        memo = store
        memo[key] = value if memo
      end

      private

      def store
        ActiveSupport::IsolatedExecutionState[KEY]
      end
    end
  end
end
