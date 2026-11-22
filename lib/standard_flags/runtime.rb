require "standard_flags/runtime/values"
require "standard_flags/runtime/rule_snapshot"
require "standard_flags/runtime/store"
require "standard_flags/runtime/memory_store"
require "standard_flags/runtime/cache"
require "standard_flags/runtime/resolver"

module StandardFlags
  # Runtime rules: per-flag rules stored in the app's own database, read
  # between the ENV pin and the code default. Opt in with
  # `config.runtime_rules = true` after running the migrations generator.
  #
  # Nothing here touches ActiveRecord unless runtime rules are on and no
  # other store is configured; the ActiveRecord store and its models are
  # required only then.
  module Runtime
    MEMBERSHIPS_MEMO = :standard_flags_runtime_memberships

    class << self
      # A monotonic clock for refresh intervals (specs only).
      # @api private
      attr_writer :clock

      # On when the app turned runtime rules on, or a spec used `with_rule`
      # and friends.
      def enabled?
        !test_store.nil? || StandardFlags.config.runtime_rules == true
      end

      def store
        test_store || StandardFlags.config.runtime_store || default_store
      end

      # The process cache for the current store. Test stores are checked on
      # every evaluation; in-memory revision checks cost nothing.
      def cache
        current = store
        @cache = nil unless @cache&.store.equal?(current)
        @cache ||= Cache.new(current, interval: current.equal?(test_store) ? 0 : nil, clock: method(:now))
      end

      def snapshot
        cache.snapshot
      end

      # Live memberships of one unit key across every rule and cohort: one
      # store read per unit key per unit of work, memoised through Memo.
      def memberships(unit, unit_key)
        Memo.fetch([ MEMBERSHIPS_MEMO, unit, unit_key ]) { store.memberships(unit, [ unit_key ]).freeze }
      end

      # Fills the memo for many units of one kind with a single read, so a
      # loop over records doesn't run one membership query per record.
      # Returns the number of keys read (0 when nothing needed reading).
      def preload(unit, records_or_keys, registry: StandardFlags.registry)
        return 0 unless enabled? && Memo.active?

        unit = unit.to_sym
        declared = registry.units[unit]
        raise ArgumentError, "unknown unit :#{unit}" unless declared

        keys = Array(records_or_keys).filter_map { |item| declared.key_for(item) }.uniq
        keys.reject! { |key| Memo.key?([ MEMBERSHIPS_MEMO, unit, key ]) }
        return 0 if keys.empty? || !snapshot.member_rules?(registry, unit)

        found = store.memberships(unit, keys).group_by(&:unit_key)
        keys.each { |key| Memo.write([ MEMBERSHIPS_MEMO, unit, key ], (found[key] || []).freeze) }
        keys.size
      end

      # The state of the runtime layer, for diagnostics and the health check.
      def status(registry: StandardFlags.registry)
        snapshot = self.snapshot
        {
          enabled: true,
          store: store.class.name,
          ready: ready?,
          loaded: snapshot.loaded,
          stale: snapshot.stale,
          revision: snapshot.revision,
          age: snapshot.age,
          loaded_at: snapshot.loaded_at&.iso8601,
          rules: snapshot.rules.values.sort_by(&:key).map { |rule| rule_status(registry, rule) }
        }
      end

      # Whether the store's tables exist. Never raises.
      def ready?
        store.ready?
      rescue StandardError
        false
      end

      # Loads the ActiveRecord store at boot when it will be used, so the
      # first request doesn't pay for the require.
      def boot!
        default_store if StandardFlags.config.runtime_rules == true && StandardFlags.config.runtime_store.nil?
      end

      # Drops the cache (the default store and its loaded models stay).
      def reset!
        @cache = nil
        @clock = nil
      end

      # The stored string for a Ruby value: true/false become "on"/"off".
      def wire(value)
        case value
        when nil then nil
        when true then "on"
        when false then "off"
        else value.to_s
        end
      end

      private

      def now
        @clock ? @clock.call : Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def test_store
        Testing.runtime_store if Testing.active?
      end

      def default_store
        @default_store ||= begin
          require "standard_flags/runtime/active_record_store"
          ActiveRecordStore.new
        end
      end

      def rule_status(registry, rule)
        orphan = if registry.tombstoned?(rule.key) then :tombstoned
        elsif !registry.key?(rule.key) then :undeclared
        end
        { key: rule.key, status: rule.status, percentage_bps: rule.percentage_bps, member_count: rule.member_count,
          cohorts: rule.cohort_attachments.map(&:first), orphan: orphan }
      end
    end
  end
end
