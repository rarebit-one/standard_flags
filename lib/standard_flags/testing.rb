module StandardFlags
  # Test overrides, the first layer of evaluation. Inert until
  # `require "standard_flags/rspec"` (or a host's own harness) calls
  # `activate!`, so production code paths never read them.
  module Testing
    NONE = Object.new.freeze

    @overrides = {}
    @active = false

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

      # Clears overrides, the once-per-process report memory and the memo.
      def reset!
        @overrides = {}.freeze
        Reporting.reset!
        Memo.clear!
      end

      private

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
