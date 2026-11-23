module StandardFlags
  # Reads a flag's environment variables without side effects.
  #
  # The canonical STANDARD_FLAGS_<KEY> is read first, then each legacy `env:`
  # name in declared order. The first variable that parses wins, so a valid
  # canonical pin beats any legacy one. `inverted: true` flips legacy values
  # only (a legacy *_DISABLED=true means the flag is off), and
  # `legacy_parser: :exact` changes how legacy values parse, never the
  # canonical one. A blank value counts as unset, except a blank exact legacy
  # value on a non-inverted on/off flag, which pins it off.
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
        is_legacy = var != definition.canonical_env_var
        next if Parser.blank?(raw) && !(is_legacy && blank_pins_off?(definition, raw))

        legacy << var if is_legacy
        value = is_legacy ? Parser.parse_legacy(definition, raw) : Parser.parse(definition, raw)
        if value.equal?(Parser::INVALID)
          rejected << var
        elsif pin.nil?
          value = !value if is_legacy && definition.inverted
          pin = Pin.new(var: var, value: value, legacy: is_legacy)
        end
      end

      Scan.new(pin: pin, rejected: rejected.freeze, legacy: legacy.freeze)
    end

    # Under `legacy_parser: :exact`, a set-but-blank legacy value pins an
    # on/off flag off, as `ENV["X"] == "on"` did; only an unset variable
    # falls through. Not for inverted names: off there would turn the flag
    # on, so a blank one stays unset. Modes keep blank as unset too.
    def blank_pins_off?(definition, raw)
      !raw.nil? && definition.legacy_parser == :exact && definition.boolean? && !definition.inverted
    end
  end
end
