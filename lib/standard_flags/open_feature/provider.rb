module StandardFlags
  module OpenFeature
    # An OpenFeature provider for the openfeature-sdk gem. Each fetch
    # evaluates the flag through the same chain as `StandardFlags.evaluate`
    # (test override, guard, ENV pin, runtime rule, code default) and returns
    # the SDK's ResolutionDetails.
    #
    # * Booleans: `flag`, `kill_switch` and `compat` answer
    #   `fetch_boolean_value`; a mode (its value name) and an experiment (its
    #   variant) answer `fetch_string_value`. Any other pairing, and every
    #   number or object fetch, returns the caller's default with
    #   TYPE_MISMATCH.
    # * Reasons and error codes map 1:1; ENV_PIN and KILL_SWITCH pass
    #   through as custom reasons. `kind`, `rule_id` and `source_env_var` go
    #   in `flag_metadata`.
    # * An unknown key returns the caller's default with FLAG_NOT_FOUND, even
    #   when `config.strict` is on: a provider never raises.
    #
    # The EvaluationContext becomes a StandardFlags::Context:
    #
    # * `targeting_key` is the key of the flag's declared unit; a field named
    #   after a unit (`organization`, say) sets that unit's key, and wins over
    #   `targeting_key` for a flag on that unit. Only the flag's own unit key
    #   must be a scalar; another unit's field that isn't one is ignored.
    # * `platform`, `appVersion` / `app_version` and `build` are the client.
    # * `env` overrides the environment only with `allow_env_override: true`,
    #   and never relaxes a `forbidden_in:` guard (Resolvers::Guard also
    #   checks the registry's own environment).
    #
    # These keys are used as given: a unit's `from:` and `key:` are not
    # applied to them, since they are already keys rather than records, and
    # `config.segment_resolver` sees the same keys.
    #
    # There is no `init`: a provider without one is ready as soon as it is
    # set (spec 2.8.5.1), and the registry and rules load on first use as
    # they do outside OpenFeature. `shutdown` does nothing.
    class Provider
      NAME = "standard_flags".freeze

      OF = ::OpenFeature::SDK::Provider

      REASONS = {
        Reason::STATIC => OF::Reason::STATIC,
        Reason::DEFAULT => OF::Reason::DEFAULT,
        Reason::TARGETING_MATCH => OF::Reason::TARGETING_MATCH,
        Reason::SPLIT => OF::Reason::SPLIT,
        Reason::DISABLED => OF::Reason::DISABLED,
        Reason::ERROR => OF::Reason::ERROR,
        Reason::ENV_PIN => Reason::ENV_PIN,
        Reason::KILL_SWITCH => Reason::KILL_SWITCH
      }.freeze

      ERROR_CODES = {
        ErrorCode::FLAG_NOT_FOUND => OF::ErrorCode::FLAG_NOT_FOUND,
        ErrorCode::PARSE_ERROR => OF::ErrorCode::PARSE_ERROR,
        ErrorCode::TYPE_MISMATCH => OF::ErrorCode::TYPE_MISMATCH,
        ErrorCode::TARGETING_KEY_MISSING => OF::ErrorCode::TARGETING_KEY_MISSING,
        ErrorCode::INVALID_CONTEXT => OF::ErrorCode::INVALID_CONTEXT,
        ErrorCode::PROVIDER_NOT_READY => OF::ErrorCode::PROVIDER_NOT_READY,
        ErrorCode::PROVIDER_FATAL => OF::ErrorCode::PROVIDER_FATAL,
        ErrorCode::GENERAL => OF::ErrorCode::GENERAL
      }.freeze

      # Which kinds answer which fetch. Kinds missing from a list mismatch.
      FETCHES = {
        boolean: Definition::BOOLEAN_KINDS,
        string: %i[mode experiment],
        number: [],
        integer: [],
        float: [],
        object: []
      }.freeze

      CLIENT_FIELDS = Client::CONTEXT_FIELDS

      # A context field that can't be a unit key (a Hash, say).
      class InvalidContext < StandardError; end

      attr_reader :metadata

      # `allow_env_override: true` lets the context's `env` field pick the
      # environment for per-environment defaults. Off by default: `env` is a
      # common attribute name in merged OpenFeature contexts.
      def initialize(allow_env_override: false)
        raise ArgumentError, "allow_env_override: must be true or false" unless [ true, false ].include?(allow_env_override)

        @metadata = OF::ProviderMetadata.new(name: NAME).freeze
        @allow_env_override = allow_env_override
        @registries = nil
      end

      def hooks
        []
      end

      def shutdown; end

      FETCHES.each_key do |type|
        define_method(:"fetch_#{type}_value") do |flag_key:, default_value:, evaluation_context: nil|
          fetch(type, flag_key, default_value, evaluation_context)
        end
      end

      private

      def fetch(type, flag_key, default_value, evaluation_context)
        source = StandardFlags.registry
        key = flag_key.to_s.to_sym
        definition = source[key]
        return not_found(source, key, default_value) unless definition
        return mismatch(definition, type, default_value) unless FETCHES.fetch(type).include?(definition.kind)

        registry = keyed_registry(source)
        context = context_for(registry, definition, evaluation_context)
        details(definition, Reader.new(registry, context).evaluate(key))
      rescue InvalidContext => e
        failure(default_value, ErrorCode::INVALID_CONTEXT, e.message, definition)
      rescue StandardError => e
        Reporting.once(:open_feature, key, e.class.name) { Reporting.report(e, flag: key.to_s) }
        failure(default_value, ErrorCode::GENERAL, "#{e.class} while evaluating #{flag_key}", definition)
      end

      def details(definition, evaluation)
        OF::ResolutionDetails.new(
          value: evaluation.value.is_a?(Symbol) ? evaluation.value.to_s : evaluation.value,
          variant: evaluation.variant,
          reason: REASONS.fetch(evaluation.reason, evaluation.reason),
          error_code: evaluation.error_code && ERROR_CODES.fetch(evaluation.error_code, OF::ErrorCode::GENERAL),
          flag_metadata: metadata_for(definition, evaluation)
        )
      end

      def metadata_for(definition, evaluation = nil)
        {
          "kind" => definition&.kind&.to_s,
          "rule_id" => evaluation&.rule_id,
          "source_env_var" => evaluation&.source_env_var
        }.compact
      end

      def not_found(registry, key, default_value)
        message =
          if registry.tombstoned?(key)
            "flag :#{key} was removed on #{registry.tombstones[key].removed.iso8601}"
          else
            "unknown flag :#{key}; declare it in config/flags.rb"
          end
        Reporting.once(:unknown, key) { Reporting.report(UnknownFlag.new(message), flag: key.to_s) }
        failure(default_value, ErrorCode::FLAG_NOT_FOUND, message, nil)
      end

      def mismatch(definition, type, default_value)
        message = "flag :#{definition.key} is a #{definition.kind}; fetch it as #{expected_type(definition)}, not #{type}"
        Reporting.once(:type_mismatch, definition.key, type) { Reporting.report(TypeMismatch.new(message)) }
        failure(default_value, ErrorCode::TYPE_MISMATCH, message, definition)
      end

      def expected_type(definition)
        FETCHES.find { |_, kinds| kinds.include?(definition.kind) }.first
      end

      def failure(default_value, error_code, message, definition)
        OF::ResolutionDetails.new(
          value: default_value,
          reason: OF::Reason::ERROR,
          error_code: ERROR_CODES.fetch(error_code),
          error_message: message,
          flag_metadata: metadata_for(definition)
        )
      end

      # The app's registry with each unit reading its key straight from the
      # context's actors, skipping `from:` and `key:`: OpenFeature callers
      # pass keys, not records. Rebuilt only when the app's registry changes.
      def keyed_registry(source)
        cached = @registries
        return cached.last if cached&.first.equal?(source)

        units = source.units.to_h do |name, _|
          [ name, Registry::Unit.new(name: name, resolver: ->(context) { context.actors[name] }, key: nil) ]
        end
        keyed = Registry.new(
          flags: source.keys.zip(source.definitions).to_h,
          tombstones: source.tombstones,
          units: units,
          env_resolver: -> { source.current_env }
        )
        @registries = [ source, keyed ].freeze
        keyed
      end

      # Only the flag's own unit key (its field, else `targeting_key`) must be
      # a scalar. Other units' fields only reach a segment resolver, so one
      # that can't be a key (structured attributes from a merged context, say)
      # is dropped rather than failing every flag.
      def context_for(registry, definition, evaluation_context)
        fields = evaluation_context&.fields || {}
        actors = registry.units.each_key.with_object({}) do |unit, found|
          key = unit_key(fields, unit.to_s, strict: unit == definition.unit)
          found[unit] = key if key
        end
        if definition.unit && !actors.key?(definition.unit)
          key = unit_key(fields, ::OpenFeature::SDK::EvaluationContext::TARGETING_KEY, strict: true)
          actors[definition.unit] = key if key
        end
        env = present(fields["env"]) if @allow_env_override
        Context.new(actors: actors, env: env, client: client(fields))
      end

      def unit_key(fields, name, strict:)
        value = fields[name]
        case value
        when nil then nil
        when String, Symbol, Integer then present(value.to_s)
        else
          raise InvalidContext, "context field #{name} must be a string key, not a #{value.class}" if strict
        end
      end

      def client(fields)
        CLIENT_FIELDS.each_with_object({}) do |(attribute, names), client|
          value = names.lazy.map { |name| present(fields[name]) }.find(&:itself)
          client[attribute] = value unless value.nil?
        end
      end

      def present(value)
        value unless value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
