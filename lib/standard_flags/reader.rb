module StandardFlags
  # The typed read API over one context. `StandardFlags.on?` and friends build
  # one per call; Snapshot is a Reader over pre-computed evaluations.
  class Reader
    READERS = { boolean: "on?", mode: "mode", experiment: "variant" }.freeze

    attr_reader :registry, :context

    def initialize(registry, context)
      @registry = registry
      @context = context
    end

    def evaluate(key)
      Evaluator.evaluate(registry, key, context)
    end
    alias peek evaluate

    def on?(key)
      evaluation = evaluate(key)
      return false unless kind?(key, :boolean)

      evaluation.value == true
    end

    def off?(key)
      !on?(key)
    end

    def mode(key)
      evaluation = evaluate(key)
      return Mode.unknown unless kind?(key, :mode)

      Mode.new(evaluation.value, registry[key].values)
    end

    def variant(key)
      evaluate(key).variant
    end

    # What `requires_flag` checks: an on/off flag is on, or a mode is past its
    # first (off) value.
    def enabled?(key)
      evaluation = evaluate(key)
      return false unless kind?(key, :boolean, :mode)

      definition = registry[key]
      definition.boolean? ? evaluation.value == true : evaluation.value != definition.off_value
    end

    private

    # Unknown keys were already handled by `evaluate` (raised when strict).
    # A kind mismatch raises when strict and reads as off otherwise.
    def kind?(key, *expected)
      definition = registry[key]
      return false unless definition

      actual = definition.boolean? ? :boolean : definition.kind
      return true if expected.include?(actual)

      message = "flag :#{definition.key} is a #{definition.kind}; read it with #{READERS.fetch(actual)}"
      raise TypeMismatch, message if StandardFlags.config.strict?

      Reporting.once(:type_mismatch, definition.key, expected) { Reporting.report(TypeMismatch.new(message)) }
      false
    end
  end
end
