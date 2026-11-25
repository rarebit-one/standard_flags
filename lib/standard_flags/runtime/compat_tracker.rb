module StandardFlags
  module Runtime
    # One row of standard_flags_compat_stats: how often a compat flag was
    # evaluated by clients on one platform, the oldest client version seen
    # there (a String, nil when none was known) and when it was last hit.
    # The platform is the client's, "unknown" for one this app doesn't
    # recognise, or "none" when the evaluation carried no client.
    #
    # The row whose platform is "*" (CompatTracker::TRACKING) is the flag's
    # tracking marker, written with no hits by every successful write: its
    # `first_seen_at` says since when the counts can be trusted, and its
    # `last_hit_at` (read as `last_flushed_at`) when a write last succeeded.
    CompatStat = Data.define(:key, :platform, :hits, :oldest_version, :last_hit_at, :first_seen_at) do
      def initialize(key:, platform:, hits:, oldest_version:, last_hit_at:, first_seen_at: nil)
        super
      end

      def marker?
        platform == CompatTracker::TRACKING
      end

      # When a write last succeeded, for a tracking marker; nil otherwise.
      def last_flushed_at
        last_hit_at if marker?
      end

      def to_h
        { key: key, platform: platform, hits: hits, oldest_version: oldest_version, last_hit_at: last_hit_at&.utc&.iso8601 }
      end
    end

    # How stores combine a stored CompatStat with new counts.
    #
    # @api private
    module CompatStats
      module_function

      # `stored` (or nil) plus `added`: hits add up, the later hit wins and
      # `first_seen_at` is the stored one (or `now` for a new row). The
      # older version wins, unless the row had gone unused for
      # CompatTracker::IDLE before this hit, in which case the new oldest
      # version replaces it: an old spoofed or long-gone version doesn't
      # stick forever. The key is a String.
      def merge(stored, added, now: Time.now.utc)
        return added.with(key: added.key.to_s, first_seen_at: added.first_seen_at || now) if stored.nil?

        oldest =
          if idle_before?(stored.last_hit_at, added.last_hit_at) then added.oldest_version
          else older(stored.oldest_version, added.oldest_version)
          end
        CompatStat.new(key: stored.key.to_s, platform: stored.platform, hits: stored.hits + added.hits,
                       oldest_version: oldest, last_hit_at: [ stored.last_hit_at, added.last_hit_at ].compact.max,
                       first_seen_at: stored.first_seen_at)
      end

      def idle_before?(stored_hit, new_hit)
        !stored_hit.nil? && !new_hit.nil? && stored_hit < new_hit - CompatTracker::IDLE
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
    # `config.evaluation_tracking_interval` per process (failed writes
    # included), the counts are added to standard_flags_compat_stats with a
    # tracking marker per compat window, refreshed by every write that
    # succeeds (one write per interval even without hits, so a quiet
    # window still shows tracking is healthy).
    # It is best-effort: a failed write is reported once per process, emits
    # `compat_tracking_failed` once per interval, and the counts are kept
    # for the next try (the table holds one entry per flag and platform, so
    # it stays small).
    #
    # Hits count from every evaluation; the oldest version only from
    # clients on a platform in `config.client_platforms`. Versions come from
    # client headers, which anyone can send, so the oldest version is a
    # hint, not proof.
    #
    # Operator reads (MCP tools, diagnostics) don't count, so they can't
    # keep a dead shim looking alive. A forked child starts with no
    # pending counts (its parent writes them). `config.track_compat` (off by
    # default) turns it on; it needs runtime rules and the compat stats
    # migration.
    class CompatTracker
      UNTRACKED = :standard_flags_compat_untracked
      NO_PLATFORM = "none".freeze
      # The platform of a flag's tracking marker row.
      TRACKING = "*".freeze
      # How long a flag must go unused (and tracking must have run) before
      # flags:stale calls its window removable.
      IDLE = 14 * 86_400
      # How recent the last successful write must be for flags:stale to
      # trust that missing hits mean no use.
      HEALTHY = 2 * 86_400

      Pending = Struct.new(:hits, :oldest, :last_hit_at)

      def initialize
        @mutex = Mutex.new
        reset
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
          forked!
          entry = (@counts[[ definition.key, platform ]] ||= Pending.new(0, nil, nil))
          entry.hits += 1
          entry.oldest = version if version && (entry.oldest.nil? || version < entry.oldest)
          entry.last_hit_at = now
        end
      end

      # Called by Runtime.unit_of_work_complete! with its monotonic clock.
      # Never raises. The interval is claimed before writing, and a failed
      # write keeps the claim, so a struggling database sees at most one
      # attempt per interval per process. Only a write the store skipped
      # (nil: an open transaction, or a store that keeps no stats) may be
      # tried again at the next unit of work.
      def flush(store, now, registry: StandardFlags.registry)
        config = StandardFlags.config
        return unless config.track_compat

        batch = @mutex.synchronize do
          forked!
          next if @flushed_at && now - @flushed_at < config.evaluation_tracking_interval.to_f

          @flushed_at = now
          @counts.tap { @counts = {} }
        end
        return unless batch

        windows = registry.definitions.select(&:compat_window?).map(&:key)
        write(store, batch, windows) unless batch.empty? && windows.empty?
      end

      # Counts not yet written, as CompatStats.
      def pending
        @mutex.synchronize do
          forked!
          stats(@counts)
        end
      end

      private

      def reset
        @counts = {}
        @flushed_at = nil
        @pid = Process.pid
      end

      # Called under the lock.
      def forked!
        reset unless @pid == Process.pid
      end

      def write(store, batch, windows)
        flushed_at = Time.now.utc
        markers = windows.map { |key| CompatStat.new(key: key, platform: TRACKING, hits: 0, oldest_version: nil, last_hit_at: flushed_at) }
        written = begin
          store.record_compat(stats(batch) + markers)
        rescue StandardError => e
          failed(e)
          return restore(batch, keep_clock: true)
        end
        restore(batch, keep_clock: false) if written.nil?
      end

      def stats(counts)
        counts.map do |(key, platform), entry|
          CompatStat.new(key: key, platform: platform, hits: entry.hits, oldest_version: entry.oldest&.to_s,
                         last_hit_at: entry.last_hit_at)
        end.sort_by { |stat| [ stat.key.to_s, stat.platform ] }
      end

      # Puts back counts a write didn't take, merged with any since.
      def restore(batch, keep_clock:)
        @mutex.synchronize do
          @flushed_at = nil unless keep_clock
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
