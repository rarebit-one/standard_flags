module StandardFlags
  # Every declared flag evaluated once for one context, frozen. Pass it
  # through a batch (a webhook fan-out, an import) so every record sees the
  # same answers even if a pin changes halfway through.
  #
  #   snap = StandardFlags.snapshot(for: account)
  #   rows.each { |row| process(row) if snap.on?(:new_importer) }
  class Snapshot < Reader
    def self.build(registry, context)
      evaluations = registry.keys.to_h { |key| [ key, Evaluator.evaluate(registry, key, context) ] }
      new(registry, context, evaluations)
    end

    def initialize(registry, context, evaluations)
      super(registry, context)
      @evaluations = evaluations.freeze
      freeze
    end

    def evaluate(key)
      @evaluations.fetch(key.to_sym) { Evaluator.unknown(registry, key.to_sym) }
    end
    alias peek evaluate
    alias [] evaluate

    def to_h
      @evaluations
    end

    def each(&)
      @evaluations.each_value(&)
    end
  end
end
