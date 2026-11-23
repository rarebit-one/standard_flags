module StandardFlags
  # Test overrides, the first layer of evaluation. Inert until
  # `require "standard_flags/rspec"` (or a host's own harness) calls
  # `activate!`, so production code paths never read them.
  module Testing
    NONE = Object.new.freeze

    @overrides = {}
    @active = false
    @runtime_store = nil

    class << self
      def activate!
        @active = true
      end

      # @api private — lets the gem's own specs prove overrides are inert.
      def deactivate!
        @active = false
      end

      def active?
        @active
      end

      # Sets an override until `reset!`. The value is checked against the
      # declaration, so a typo'd key or value fails the spec.
      def override(key, value, kind: nil)
        definition = definition_for(key, kind)
        @overrides = @overrides.merge(definition.key => cast(definition, value)).freeze
        Memo.clear!
      end

      # Applies overrides for the duration of the block, then restores the
      # previous set.
      def with(overrides, kind: nil)
        previous = @overrides
        overrides.each { |key, value| override(key, value, kind: kind) }
        yield
      ensure
        @overrides = previous
        Memo.clear!
      end

      def override_for(key)
        @overrides.fetch(key, NONE)
      end

      def overrides
        @overrides
      end

      # The in-memory runtime store behind `rule`, `members` and `cohort`, or
      # nil when the example set none. While set, runtime rules are on and
      # read from it, whatever the app's own runtime configuration.
      def runtime_store
        @runtime_store
      end

      # Stores a runtime rule for a declared flag. Takes Ruby values:
      #
      #   Testing.rule(:new_checkout, percentage: 5_000)          # running, 50%
      #   Testing.rule(:strict_gates, fallthrough: :sensor)
      #   Testing.rule(:home_hero, variants: { "control" => 5_000, "savings" => 5_000 })
      #   Testing.rule(:new_checkout, status: :stopped, stop: true)
      #   Testing.rule(:new_checkout, cohorts: { staff: true }, platforms: %w[ios], versions: { ios: ">= 2.0" })
      #
      # The salt and hash version default to the flag's `bucketing:` or to
      # (key, 2).
      def rule(key, status: :running, percentage: nil, rollout: nil, variants: nil, fallthrough: nil, stop: nil,
               cohorts: nil, segments: nil, platforms: nil, versions: nil, salt: nil, hash_version: nil)
        definition = definition_for(key, nil)
        conditions = { "segments" => segment_list(segments), "platforms" => platforms&.map(&:to_s),
                       "versions" => versions&.to_h { |platform, range| [ platform.to_s, range.to_s ] } }.compact
        attributes = {
          status: status, percentage_bps: percentage, rollout_value: rollout, variant_weights: variants || {},
          fallthrough_value: fallthrough, stop_value: stop, conditions: conditions, cohorts: cohorts || [],
          salt: salt || definition.bucketing&.salt || definition.key.to_s,
          hash_version: hash_version || definition.bucketing&.version || 2
        }
        check_rule_values!(definition, rollout, fallthrough, stop, variants&.keys, cohorts, segments)
        runtime_test_store.put_rule(definition.key, **attributes).tap { Memo.clear! }
      end

      # Adds units (records or keys) as direct members of a flag's rule,
      # serving `value`. Creates a running rule with no other settings if
      # there is none yet.
      def members(key, units, value: true, expires_at: nil)
        definition = definition_for(key, nil)
        unit = unit_for(definition)
        value = cast(definition, value)
        rule(key) unless runtime_test_store.rule(definition.key)
        unit_keys(unit, units).each do |unit_key|
          runtime_test_store.add_member(rule: definition.key, unit: unit.name, unit_key: unit_key,
                                        value: Runtime.wire(value), expires_at: expires_at)
        end
        Memo.clear!
      end

      # Defines a cohort of one unit with these members (records or keys).
      # Attach it with `rule(key, cohorts: { cohort_key => value })`.
      def cohort(key, unit:, members: [], expires_at: nil, archived: false)
        declared = StandardFlags.registry.units[unit.to_sym]
        raise ArgumentError, "unknown unit :#{unit}" unless declared

        store = runtime_test_store
        store.put_cohort(key, unit: declared.name, archived_at: archived ? Time.now : nil)
        unit_keys(declared, members).each do |unit_key|
          store.add_member(cohort: key, unit: declared.name, unit_key: unit_key, value: "on", expires_at: expires_at)
        end
        Memo.clear!
      end

      # Clears overrides, runtime test rules, the once-per-process report
      # memory and the memo.
      def reset!
        @overrides = {}.freeze
        @runtime_store = nil
        Runtime.reset!
        Reporting.reset!
        Memo.clear!
      end

      private

      def runtime_test_store
        @runtime_store ||= Runtime::MemoryStore.new
      end

      def unit_for(definition)
        unit = definition.unit && StandardFlags.registry.units[definition.unit]
        raise ArgumentError, "flag :#{definition.key} has no unit: to target" unless unit

        unit
      end

      def unit_keys(unit, units)
        units = [ units ] unless units.is_a?(Array)
        units.map do |item|
          unit.key_for(item) || raise(ArgumentError, "#{item.inspect} has no key for unit :#{unit.name}")
        end
      end

      def segment_list(segments)
        return nil if segments.nil?

        segments.map { |name, value| { "name" => name.to_s, "value" => Runtime.wire(value) } }
      end

      # Every value a test rule serves must be one the flag can take, so a
      # typo fails the spec. (Put invalid rows on a MemoryStore directly to
      # test PARSE_ERROR.)
      def check_rule_values!(definition, rollout, fallthrough, stop, variants, cohorts, segments)
        served = [ rollout, fallthrough, stop ] + Array(variants)
        served += cohorts.is_a?(Hash) ? cohorts.values : Array(cohorts).map { |a| a.to_h.transform_keys(&:to_s)["value"] }
        served += Array(segments).map(&:last)
        served.compact.each { |value| cast(definition, value) }
      end

      def definition_for(key, kind)
        definition = StandardFlags.registry[key]
        raise UnknownFlag, "cannot override unknown flag :#{key}" unless definition

        expected = Array(kind)
        unless expected.empty? || expected.include?(definition.kind)
          raise TypeMismatch, "flag :#{key} is a #{definition.kind}, not a #{expected.join(' or ')}"
        end

        definition
      end

      def cast(definition, value)
        cast =
          if definition.boolean? then value
          elsif definition.mode? then value.respond_to?(:to_sym) ? value.to_sym : value
          else value.to_s
          end
        return cast if definition.allowed_values.include?(cast)

        raise ArgumentError, "#{value.inspect} is not one of #{definition.allowed_values.inspect} for :#{definition.key}"
      end
    end
  end
end
