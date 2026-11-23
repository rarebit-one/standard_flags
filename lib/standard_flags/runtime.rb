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
    SNAPSHOT_MEMO = :standard_flags_runtime_snapshot

    # What `memberships` returns, and memoises for the rest of the unit of
    # work, when the lookup failed.
    LOOKUP_FAILED = Object.new.tap { |o| def o.inspect = "#<StandardFlags::Runtime::LOOKUP_FAILED>" }.freeze

    # Stands in for a unit key whose `from:` or `key:` raised.
    UNRESOLVED = Object.new.tap { |o| def o.inspect = "#<StandardFlags::Runtime::UNRESOLVED>" }.freeze

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

      # The rules snapshot. Inside a unit of work the first call pins it, so
      # every evaluation in that request or job sees one revision; outside
      # one, each call reads the process cache.
      def snapshot
        current = cache
        Memo.fetch([ SNAPSHOT_MEMO, current ]) { current.snapshot }
      end

      # The flag's unit key in `context`, through the unit's `from:` and
      # `key:`; nil when the flag has no unit or the context has no actor for
      # it. A `from:` like `->(ctx) { ctx.account }` on a context without an
      # account reads as no actor; anything else a host lambda raises
      # propagates.
      def unit_key(registry, definition, context)
        return nil unless definition.unit

        registry.units[definition.unit]&.key_from(context)
      rescue NoMethodError => e
        raise unless e.receiver.equal?(context)
      end

      # Live memberships of one unit key across every rule and cohort: one
      # store read per unit key per unit of work, memoised through Memo. A
      # failed read is reported once and memoised as LOOKUP_FAILED, so an
      # outage costs one failed query per unit per unit of work.
      def memberships(unit, unit_key)
        Memo.fetch([ MEMBERSHIPS_MEMO, unit, unit_key ]) do
          store.memberships(unit, [ unit_key ]).freeze
        rescue StandardError => e
          read_failed(:memberships, e)
          LOOKUP_FAILED
        end
      end

      # Fills the memo for many units of one kind with a single read, so a
      # loop over records doesn't run one membership query per record.
      # Returns the number of keys read (0 when nothing needed reading).
      #
      # Never raises for a store error or a raising `key:`: it reports once
      # and returns 0 without memoising, and each evaluation then reads (or
      # fails) on its own.
      def preload(unit, records_or_keys, registry: StandardFlags.registry)
        return 0 unless enabled? && Memo.active?

        unit = unit.to_sym
        declared = registry.units[unit]
        raise ArgumentError, "unknown unit :#{unit}" unless declared

        preload_keys(declared, unit, records_or_keys, registry)
      end

      # The state of the runtime layer, for diagnostics and the health check.
      # `ready` is false only when the store answered that its tables are
      # missing; `unreachable` names the error class when it couldn't answer.
      def status(registry: StandardFlags.registry)
        snapshot = self.snapshot
        readiness = self.readiness
        {
          enabled: true,
          store: store.class.name,
          ready: readiness == true,
          unreachable: (readiness unless readiness == true || readiness == false),
          warnings: store_warnings,
          loaded: snapshot.loaded,
          stale: snapshot.stale,
          revision: snapshot.revision,
          age: snapshot.age,
          loaded_at: snapshot.loaded_at&.iso8601,
          rules: snapshot.rules.values.sort_by(&:key).map { |rule| rule_status(registry, rule) }
        }
      end

      # Whether the store's tables exist. Never raises: false when they are
      # missing or the store can't be reached.
      def ready?
        readiness == true
      end

      # true, false (tables missing), or the class name of the error that
      # stopped the store from answering. Never raises.
      def readiness
        store.ready? ? true : false
      rescue StandardError => e
        (e.cause_class if e.is_a?(StoreError)) || e.class.name
      end

      # Called by the engine after boot. With runtime rules on, adds
      # `unit_key` to ActiveRecord::Base's filter once ActiveRecord loads, and
      # loads the ActiveRecord store when it will be used, so the first
      # request doesn't pay for the require. With them off, does nothing.
      def boot!
        return unless StandardFlags.config.runtime_rules == true

        ActiveSupport.on_load(:active_record) { StandardFlags::Runtime.filter_unit_keys!(self) }
        default_store if StandardFlags.config.runtime_store.nil?
      end

      # Adds `unit_key` to `base.filter_attributes` (ActiveRecord::Base),
      # which SQL logs filter binds through. Global, so the name is narrow;
      # idempotent.
      def filter_unit_keys!(base)
        current = base.filter_attributes
        base.filter_attributes = current + [ :unit_key ] unless current.any? { |f| f.to_s == "unit_key" }
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

      def preload_keys(declared, unit, records_or_keys, registry)
        keys = Array(records_or_keys).filter_map { |item| declared.key_for(item) }.uniq
        keys.reject! { |key| Memo.key?([ MEMBERSHIPS_MEMO, unit, key ]) }
        return 0 if keys.empty? || !snapshot.member_rules?(registry, unit)

        found = store.memberships(unit, keys).group_by(&:unit_key)
        keys.each { |key| Memo.write([ MEMBERSHIPS_MEMO, unit, key ], (found[key] || []).freeze) }
        keys.size
      rescue StandardError => e
        read_failed(:preload, e)
        0
      end

      # Reports a failed read once per kind and error class. A store's own
      # StoreError is already free of unit keys; anything else (a host
      # `key:` lambda, say) is reported by class only, since its message
      # could quote one.
      def read_failed(kind, error)
        name = (error.cause_class if error.is_a?(StoreError)) || error.class.name
        Reporting.once(:runtime_read, kind, name) do
          safe = error.is_a?(StoreError) ? error : StoreError.new("#{kind} failed: #{error.class}", cause_class: name)
          Reporting.report(safe, runtime: kind.to_s)
        end
      end

      def store_warnings
        Array(store.warnings)
      rescue StandardError
        []
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
