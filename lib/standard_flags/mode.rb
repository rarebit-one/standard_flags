module StandardFlags
  # The value of a mode flag, with one predicate per declared value:
  #
  #   mode = StandardFlags.mode(:checkout_gate)   # values: off, sensor, on
  #   mode.sensor?          # => true
  #   mode.at_least?(:sensor)
  #
  # A predicate for an undeclared value raises NoMethodError, so a typo fails
  # loudly instead of reading as false.
  class Mode
    attr_reader :value, :values

    # A mode for an unknown key or a kind mismatch outside strict mode: every
    # predicate is false.
    def self.unknown
      @unknown ||= new(nil, [])
    end

    def initialize(value, values)
      @value = value
      @values = values.freeze
      freeze
    end

    def unknown?
      values.empty?
    end

    # True when the value is `other` or comes after it in the declared order.
    def at_least?(other)
      return false if unknown?

      index = values.index(other.to_sym) or raise ArgumentError, "#{other.inspect} is not one of #{values.inspect}"
      values.index(value) >= index
    end

    def to_sym
      value
    end

    def to_s
      value.to_s
    end

    def ==(other)
      case other
      when Mode then value == other.value
      when Symbol, String then value.to_s == other.to_s
      else false
      end
    end
    alias eql? ==

    def hash
      value.hash
    end

    def inspect
      "#<StandardFlags::Mode #{value.inspect}>"
    end

    def respond_to_missing?(name, include_private = false)
      predicate?(name) || super
    end

    def method_missing(name, *args)
      return super unless predicate?(name) && args.empty?

      !unknown? && value == name.to_s.delete_suffix("?").to_sym
    end

    private

    def predicate?(name)
      name.end_with?("?") && (unknown? || values.include?(name.to_s.delete_suffix("?").to_sym))
    end
  end
end
