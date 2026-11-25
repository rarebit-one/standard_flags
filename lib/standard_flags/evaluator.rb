module StandardFlags
  # Turns (registry, key, context) into an Evaluation.
  #
  # Errors are isolated per flag: anything raised while resolving one flag
  # returns that flag's `fail:` value with reason ERROR, reports once through
  # Rails.error, and leaves every other flag alone.
  #
  # @api private
  module Evaluator
    module_function

    def evaluate(registry, key, context)
      key = key.to_sym
      definition = registry[key]
      return unknown(registry, key) unless definition

      evaluation = Memo.fetch(memo_key(registry, definition, context)) { resolve(registry, definition, context) }
      Runtime.track_compat(definition, context) if definition.compat_window?
      sample(evaluation)
      evaluation
    end

    # With runtime rules on, the answer depends on the flag's unit key, which
    # a unit's `key:` can derive from something other than the actor's id;
    # so the resolved key joins the memo key.
    def memo_key(registry, definition, context)
      key = [ definition.key, context.cache_key ]
      return key unless definition.unit && Runtime.enabled?

      key + [ Runtime.unit_key(registry, definition, context) ]
    rescue StandardError
      key + [ Runtime::UNRESOLVED ]
    end

    def resolve(registry, definition, context)
      request = Resolvers::Request.new(
        registry: registry,
        definition: definition,
        context: context,
        env_name: (context.env || registry.current_env).to_s,
        env: StandardFlags.config.env_source
      )
      Resolvers::CHAIN.each do |resolver|
        evaluation = resolver.call(request)
        return evaluation if evaluation
      end
    rescue StandardError => e
      Reporting.once(:error, definition.key, e.class.name) { Reporting.report(e, flag: definition.key.to_s) }
      Evaluation.build(definition, definition.fail_value, reason: Reason::ERROR, error_code: ErrorCode::GENERAL)
    end

    def unknown(registry, key)
      message =
        if registry.tombstoned?(key)
          "flag :#{key} was removed on #{registry.tombstones[key].removed.iso8601}"
        else
          "unknown flag :#{key}; declare it in config/flags.rb"
        end
      raise UnknownFlag, message if StandardFlags.config.strict?

      Reporting.once(:unknown, key) { Reporting.report(UnknownFlag.new(message), flag: key.to_s) }
      Evaluation.not_found(key)
    end

    def sample(evaluation)
      rate = StandardFlags.config.evaluate_sample_rate.to_f
      return unless rate.positive? && (rate >= 1 || rand < rate)

      Reporting.instrument(:evaluate, evaluation.to_h)
    end
  end
end
