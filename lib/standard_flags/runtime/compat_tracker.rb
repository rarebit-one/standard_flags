module StandardFlags
  module Runtime
    # One row of standard_flags_compat_stats: how often a compat flag was
    # evaluated by clients on one platform, the oldest client version seen
    # there (a String, nil when none was known) and when it was last hit.
    # The platform is the client's, "unknown" for one this app doesn't
    # recognise, or "none" when the evaluation carried no client.
    CompatStat = Data.define(:key, :platform, :hits, :oldest_version, :last_hit_at) do
      def to_h
        { key: key, platform: platform, hits: hits, oldest_version: oldest_version, last_hit_at: last_hit_at&.utc&.iso8601 }
      end
    end

    # How stores combine a stored CompatStat with new counts.
    #
    # @api private
    module CompatStats
      module_function

      # `stored` (or nil) plus `added`: hits add up, the older version and
      # the later hit win. The key is a String.
      def merge(stored, added)
        return added.with(key: added.key.to_s) if stored.nil?

        CompatStat.new(key: stored.key.to_s, platform: stored.platform, hits: stored.hits + added.hits,
                       oldest_version: older(stored.oldest_version, added.oldest_version),
                       last_hit_at: [ stored.last_hit_at, added.last_hit_at ].compact.max)
      end

      # The older of two version Strings; one that doesn't parse loses.
      def older(first, second)
        a = Version.parse(first)
        b = Version.parse(second)
        return (a ? first : second) if a.nil? || b.nil?

        b < a ? second : first
      end
    end

    # Write-behind counts for compat windows (`compat :k, until_clients:`),
    # like EvaluationTracker: each evaluation of such a flag adds a hit and
    # the client's version to an in-memory table, and nothing is written
    # during the evaluation. When a unit of work ends, at most once per
    # `config.evaluation_tracking_interval` per process, the counts are
    # added to standard_flags_compat_stats. It is best-effort: a failed
    # write is reported once and the counts are kept for the next try (the
    # table holds one entry per flag and platform, so it stays small).
    #
    # Operator reads (MCP tools, diagnostics, flags:list and flags:show)
    # don't count, so they can't keep a dead shim looking alive.
    # `config.track_compat` (off by default) turns it on; it needs runtime
    # rules and the compat stats migration.
    class CompatTracker
      UNTRACKED = :standard_flags_compat_untracked
      NO_PLATFORM = "none".freeze

      Pending = Struct.new(:hits, :oldest, :last_hit_at)

      def initialize
        @mutex = Mutex.new
        @counts = {}
        @flushed_at = nil
      end

      # Whether evaluations on this thread or fiber are left uncounted.
      def self.untracked?
        Thread.current[UNTRACKED] || EvaluationTracker.untracked? ? true : false
      end

      # Evaluations inside the block (on this thread or fiber) are not
      # counted.
      def self.untracked
        previous = Thread.current[UNTRACKED]
        Thread.current[UNTRACKED] = true
        yield
      ensure
        Thread.current[UNTRACKED] = previous
      end

      # A platform outside `config.client_platforms` (possible in a client
      # Hash an app builds itself) counts as "unknown", so the table stays
      # one row per flag and known platform.
      def hit(definition, client, now: Time.now.utc)
        platform = client.platform
        known = platform && StandardFlags.config.client_platforms.any? { |name| name.to_s.downcase == platform }
        version = client.version if known
        platform = known ? platform : (platform || client.unknown_platform? ? Client::UNKNOWN_PLATFORM : NO_PLATFORM)
        @mutex.synchronize do
          entry = (@counts[[ definition.key, platform ]] ||= Pending.new(0, nil, nil))
          entry.hits += 1
          entry.oldest = version if version && (entry.oldest.nil? || version < entry.oldest)
          entry.last_hit_at = now
        end
      end

      # Called by Runtime.unit_of_work_complete! with its monotonic clock.
      # Never raises.
      def flush(store, now)
        config = StandardFlags.config
        return unless config.track_compat

        batch = @mutex.synchronize do
          next if @counts.empty? || (@flushed_at && now - @flushed_at < config.evaluation_tracking_interval.to_f)

          @flushed_at = now
          @counts.tap { @counts = {} }
        end
        return unless batch

        written = begin
          store.record_compat(stats(batch))
        rescue StandardError => e
          failed(e)
          nil
        end
        restore(batch) if written.nil?
      end

      # Counts not yet written, as CompatStats.
      def pending
        @mutex.synchronize { stats(@counts) }
      end

      private

      def stats(counts)
        counts.map do |(key, platform), entry|
          CompatStat.new(key: key, platform: platform, hits: entry.hits, oldest_version: entry.oldest&.to_s,
                         last_hit_at: entry.last_hit_at)
        end.sort_by { |stat| [ stat.key.to_s, stat.platform ] }
      end

      # Puts back counts a write didn't take, merged with any since.
      def restore(batch)
        @mutex.synchronize do
          @flushed_at = nil
          batch.each do |id, old|
            entry = (@counts[id] ||= Pending.new(0, nil, nil))
            entry.hits += old.hits
            entry.oldest = old.oldest if old.oldest && (entry.oldest.nil? || old.oldest < entry.oldest)
            entry.last_hit_at = [ entry.last_hit_at, old.last_hit_at ].compact.max
          end
        end
      end

      def failed(error)
        name = (error.cause_class if error.is_a?(StoreError)) || error.class.name
        Reporting.once(:compat_tracking, name) { Reporting.report(error, runtime: "compat_tracking") }
        Reporting.instrument(:compat_tracking_failed, error_class: name)
      end
    end
  end
end
