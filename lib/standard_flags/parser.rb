module StandardFlags
  # The one strict parser for every ENV value the gem reads.
  #
  # * on/off kinds accept on/off, true/false, 1/0, yes/no.
  # * modes accept their declared values; experiments their declared variants.
  #
  # Matching is trimmed and case-insensitive. Anything else is INVALID: the
  # caller ignores it and reports it. A blank value counts as unset.
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
