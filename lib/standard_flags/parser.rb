module StandardFlags
  # The one strict parser for every ENV value the gem reads.
  #
  # * on/off kinds accept on/off, true/false, 1/0, yes/no.
  # * modes accept their declared values; experiments their declared variants.
  #
  # Matching is trimmed and case-insensitive. Anything else is INVALID: the
  # caller ignores it and reports it. A blank value counts as unset.
  #
  # A flag declared `legacy_parser: :exact` reads its legacy `env:` names
  # (never the canonical pin) the way a hand-written reader did, with no
  # trimming or case folding: on/off kinds are on for a `legacy_true:` value
  # and off for anything else (EnvPin pins a set-but-blank value off too);
  # modes and experiments match a value exactly.
  module Parser
    INVALID = Object.new.tap { |o| def o.inspect = "StandardFlags::Parser::INVALID" }.freeze

    TRUE_WORDS = %w[on true 1 yes].freeze
    FALSE_WORDS = %w[off false 0 no].freeze

    module_function

    def parse(definition, raw)
      text = raw.to_s.strip.downcase
      return boolean(text) if definition.boolean?

      definition.allowed_values.find { |value| value.to_s.downcase == text } || INVALID
    end

    # Parses a legacy `env:` value with the flag's `legacy_parser:`.
    def parse_legacy(definition, raw)
      return parse(definition, raw) unless definition.legacy_parser == :exact

      text = raw.to_s
      return definition.legacy_true.include?(text) if definition.boolean?

      definition.allowed_values.find { |value| value.to_s == text } || INVALID
    end

    def boolean(raw)
      text = raw.to_s.strip.downcase
      return true if TRUE_WORDS.include?(text)
      return false if FALSE_WORDS.include?(text)

      INVALID
    end

    def blank?(raw)
      raw.nil? || raw.to_s.strip.empty?
    end
  end
end
