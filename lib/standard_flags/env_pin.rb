module StandardFlags
  # Reads a flag's environment variables without side effects.
  #
  # The canonical STANDARD_FLAGS_<KEY> is read first, then each legacy `env:`
  # name in declared order. The first variable that parses wins, so a valid
  # canonical pin beats any legacy one. `inverted: true` flips legacy values
  # only (a legacy *_DISABLED=true means the flag is off). Every name is
  # read by the one strict parser, and a blank value counts as unset.
  #
  # Callers decide what to report; Diagnostics and the health check use the
  # same scan, so they can't disagree with evaluation.
  module EnvPin
    Pin = Data.define(:var, :value, :legacy)

    # * pin      — the winning Pin, or nil.
    # * rejected — names of set variables that failed to parse.
    # * legacy   — names of legacy variables that are set (whether or not
    #              they won).
    Scan = Data.define(:pin, :rejected, :legacy) do
      # Legacy variables that are set but did not decide the value.
      def shadowed_legacy
        legacy - [ pin&.var ]
      end
    end

    module_function

    def scan(definition, env)
      pin = nil
      rejected = []
      legacy = []

      ([ definition.canonical_env_var ] + definition.env).each do |var|
        raw = env[var]
        next if Parser.blank?(raw)

        is_legacy = var != definition.canonical_env_var
        legacy << var if is_legacy
        value = Parser.parse(definition, raw)
        if value.equal?(Parser::INVALID)
          rejected << var
        elsif pin.nil?
          value = !value if is_legacy && definition.inverted
          pin = Pin.new(var: var, value: value, legacy: is_legacy)
        end
      end

      Scan.new(pin: pin, rejected: rejected.freeze, legacy: legacy.freeze)
    end
  end
end
