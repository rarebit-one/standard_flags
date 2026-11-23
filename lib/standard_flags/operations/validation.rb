require "json"
require "time"

module StandardFlags
  module Operations
    # Validation on write (R13). Everything an operation stores is checked
    # here against the flag's definition and the configured limits; the read
    # path never checks a limit. Each check raises Failure (:invalid or
    # :limit_exceeded) with a message that never quotes a unit key.
    #
    # @api private
    module Validation
      module_function

      # The stored string for a value the flag can take. Takes Ruby values
      # (true, :sensor, "savings") or stored strings ("on").
      def value!(definition, value, field)
        wire = Runtime.wire(value)
        return wire unless definition.value_from_wire(wire).equal?(Parser::INVALID)

        invalid!("#{field} #{value.inspect} is not one of #{allowed(definition)} for :#{definition.key}")
      end

      def bps!(bps)
        return bps if bps.is_a?(Integer) && (0..Bucket::BUCKETS).cover?(bps)

        invalid!("bps must be an Integer from 0 to #{Bucket::BUCKETS}, got #{bps.inspect}")
      end

      # `{ variant_or_mode_value => weight }`, weights summing to 10,000.
      # An empty Hash clears the weights.
      def weights!(definition, weights)
        invalid!(":#{definition.key} is an on/off flag; ramp it with Ramp, not variant weights") if definition.boolean?
        invalid!("weights must be a Hash of value => Integer") unless weights.is_a?(Hash)

        stored = weights.to_h { |value, weight| [ value!(definition, value, "variant"), weight ] }
        invalid!("weights name the same value twice") if stored.size != weights.size
        return stored if stored.empty?

        invalid!("weights must be Integers of 0 or more") unless stored.values.all? { |w| w.is_a?(Integer) && w >= 0 }
        sum = stored.values.sum
        invalid!("weights must sum to #{Bucket::BUCKETS}, not #{sum}") unless sum == Bucket::BUCKETS

        order = definition.allowed_values.map { |value| Runtime.wire(value) }
        stored.sort_by { |wire, _| order.index(wire) }.to_h
      end

      # The flag's declared unit; percentages, variants, segments and
      # members all need one.
      def unit!(definition, registry, what)
        unit = definition.unit && registry.units[definition.unit]
        invalid!(":#{definition.key} has no unit: declared, so it cannot have #{what}") unless unit

        unit
      end

      def version_range!(range)
        Gem::Requirement.new(*range.to_s.split(",").map(&:strip))
        range.to_s
      rescue Gem::Requirement::BadRequirementError, ArgumentError
        invalid!("version range #{range.inspect} does not parse")
      end

      def conditions_size!(conditions, config)
        bytes = JSON.generate(conditions).bytesize
        return if bytes <= config.max_conditions_bytes

        limit!("conditions are #{bytes} bytes of JSON; the limit is #{config.max_conditions_bytes}")
      end

      def keys_count!(count, config)
        return if count <= config.max_keys_per_operation

        limit!("#{count} keys in one operation; the limit is #{config.max_keys_per_operation}")
      end

      def members_count!(count, owner, config)
        return if count <= config.max_members

        limit!("#{owner} would have #{count} live members; the limit is #{config.max_members}")
      end

      def expires_at!(value, now)
        return nil if value.nil?

        time = value.is_a?(String) ? Time.iso8601(value) : value
        invalid!("expires_at must be a Time") unless time.respond_to?(:to_time)
        time = time.to_time.utc
        invalid!("expires_at must be in the future") unless time > now
        time
      rescue ArgumentError
        invalid!("expires_at #{value.inspect} is not an ISO 8601 time")
      end

      # Everything a rule would serve once running: Start checks it, and so
      # does every operation that leaves a rule running. `cohorts` maps each
      # attached key to its Cohort (missing when it doesn't exist).
      def rule!(definition, rule, registry, cohorts)
        stored_shape(definition) do
          %w[rollout_value fallthrough_value stop_value].each do |field|
            stored = rule.public_send(field)
            value!(definition, stored, field) unless stored.nil?
          end
          weights!(definition, rule.weights) if rule.weights.any?
          bps!(rule.percentage_bps) unless rule.percentage_bps.nil?
          unit!(definition, registry, "targeting") if rule.needs_unit?
          if !rule.percentage_bps.nil? && !definition.boolean? && rule.rollout_value.nil? && rule.weights.empty?
            invalid!(":#{definition.key} has a percentage but no rollout value or variant weights to serve")
          end
          rule.platforms
          rule.versions.each_value { |range| version_range!(range) }
          rule.segments.each { |segment| value!(definition, segment["value"], "segment #{segment['name']}'s value") }
          rule.cohort_attachments.each do |key, value|
            cohort!(definition, key, cohorts[key])
            value!(definition, value, "cohort #{key}'s value")
          end
        end
      end

      # The keys of the cohorts a rule attaches, in order.
      def attachments(definition, rule)
        stored_shape(definition) { rule.cohort_attachments.map(&:first) }
      end

      # A stored rule whose shape the read path rejects (a row edited by
      # hand, say) is :invalid, naming the field, not an unexpected error.
      def stored_shape(definition)
        yield
      rescue Runtime::Resolver::Invalid => e
        invalid!(":#{definition.key}'s stored rule #{e.message}")
      end

      def cohort!(definition, key, cohort)
        invalid!("cohort #{key.inspect} does not exist") unless cohort
        invalid!("cohort #{key.inspect} is archived") if cohort.archived?
        return if cohort.unit == definition.unit

        invalid!("cohort #{key.inspect} holds :#{cohort.unit} units; :#{definition.key} targets #{definition.unit.inspect}")
      end

      def allowed(definition)
        definition.allowed_values.map { |value| Runtime.wire(value) }.join("/")
      end

      def invalid!(message)
        raise Failure.new(:invalid, message)
      end

      def limit!(message)
        raise Failure.new(:limit_exceeded, message)
      end
    end
  end
end
