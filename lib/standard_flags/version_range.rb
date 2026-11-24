module StandardFlags
  # A range of client versions, in a syntax the Kotlin and TypeScript
  # clients share: comparators (`>=`, `>`, `<=`, `<`, `=`) separated by
  # spaces, all of which must hold, with optional `||` alternatives.
  # Whitespace between an operator and its version is optional, and versions
  # take the shorthands StandardFlags::Version reads.
  #
  #   range = StandardFlags::VersionRange.parse(">=1.4.0 <2.0.0 || =0.9.5-beta.1")
  #   range.satisfied_by?("1.9.3")         # => true
  #   range.to_s                           # => ">=1.4.0 <2.0.0 || =0.9.5-beta.1"
  #
  # Comparison is plain SemVer ordering, nothing more: `<2.0.0` admits
  # `2.0.0-beta.1`, which sorts before `2.0.0`. A version that doesn't parse
  # satisfies no range.
  #
  # Ranges stored before this syntax existed are RubyGems requirements
  # (`">= 1.4.0"`, `"~> 1.4"`, `">= 1.4, < 2"`); `parse` translates them on
  # read, so they keep evaluating as they did: `~> 1.4` reads as
  # `>=1.4.0 <2.0.0`, `~> 1.4.2` as `>=1.4.2 <1.5.0`, and `!= 1.5` as
  # `<1.5.0 || >1.5.0`. Only the neutral syntax is portable; the write path
  # stores it.
  class VersionRange
    class Invalid < StandardFlags::Error; end

    COMPARATOR = /(>=|<=|>|<|=)\s*([^\s<>=|]+)/
    ALTERNATIVE = /\A\s*#{COMPARATOR}(?:\s+#{COMPARATOR})*\s*\z/
    # Longest range read, and most alternatives a translated RubyGems
    # requirement may expand to.
    MAX_LENGTH = 1024
    MAX_ALTERNATIVES = 64
    CACHE_LIMIT = 1024
    CACHE_LOCK = Mutex.new

    # One `operator operand` test.
    Comparator = Data.define(:operator, :operand) do
      def satisfied_by?(value)
        order = value <=> operand
        case operator
        when ">=" then order >= 0
        when ">" then order.positive?
        when "<=" then order <= 0
        when "<" then order.negative?
        else order.zero?
        end
      end

      def to_s
        "#{operator}#{operand}"
      end
    end

    class << self
      # The range for `text` in either syntax, or nil when it parses as
      # neither. Parsed ranges are cached, so the read path parses each
      # stored range once per process.
      def parse(text)
        cached(text) { neutral(text) || legacy(text) }
      end

      def parse!(text)
        parse(text) || raise(Invalid, "#{text.inspect} is not a #{noun}")
      end

      def valid?(text)
        !parse(text).nil?
      end

      # The range for `text` in the neutral syntax only, or nil.
      def neutral(text)
        return nil unless text.is_a?(String) || text.is_a?(Symbol)

        text = text.to_s
        return nil if text.length > MAX_LENGTH

        alternatives = text.split("||", -1).map { |alternative| comparators(alternative) }
        new(alternatives) if alternatives.any? && alternatives.all?
      end

      # The neutral form of a RubyGems requirement (comma-joined), or nil
      # when it isn't one that translates.
      def translate(text)
        legacy(text)&.to_s
      end

      private

      def noun
        "version range"
      end

      # Each class keeps its own cache (nil answers included), emptied
      # when it fills.
      def cached(text)
        key = [ text.class, text.to_s ]
        CACHE_LOCK.synchronize do
          @cache ||= {}
          return @cache[key] if @cache.key?(key)
        end
        range = yield
        CACHE_LOCK.synchronize do
          @cache.clear if @cache.size >= CACHE_LIMIT
          @cache[key] = range
        end
      end

      def comparators(text)
        return nil unless ALTERNATIVE.match?(text)

        text.scan(COMPARATOR).map do |operator, raw|
          value = operand(raw)
          return nil if value.nil?

          Comparator.new(operator: operator, operand: value)
        end
      end

      def operand(text)
        Version.parse(text)
      end

      def legacy(text)
        return nil unless text.is_a?(String) || text.is_a?(Symbol)

        text = text.to_s
        return nil if text.length > MAX_LENGTH

        terms = text.split(",").map(&:strip)
        terms = [ ">= 0" ] if terms.empty? # RubyGems' default requirement
        options = terms.map { |term| legacy_term(term) }
        return nil if options.any?(&:nil?)

        combined = options.reduce([ [] ]) do |alternatives, choices|
          alternatives.product(choices).map { |left, right| left + right }
        end
        return nil if combined.size > MAX_ALTERNATIVES

        neutral(combined.map { |alternative| alternative.join(" ") }.join(" || "))
      end

      # The alternatives (each a list of comparator strings) one RubyGems
      # term means.
      def legacy_term(term)
        match = Gem::Requirement::PATTERN.match(term)
        return nil unless match

        operator = match[1] || "="
        version = legacy_version(match[2])
        return nil unless version

        case operator
        when "~>"
          upper = legacy_version(Gem::Version.new(match[2]).bump.to_s)
          upper && [ [ ">=#{version}", "<#{upper}" ] ]
        when "!=" then [ [ "<#{version}" ], [ ">#{version}" ] ]
        else [ [ "#{operator}#{version}" ] ]
        end
      end

      # A RubyGems version as SemVer: "1.4" → "1.4.0", "1.4.0.beta.1" →
      # "1.4.0-beta.1". nil past three non-zero release segments, which
      # SemVer can't hold.
      def legacy_version(text)
        direct = Version.parse(text)
        return direct.to_s if direct

        segments = Gem::Version.new(text).segments
        release = segments.take_while { |segment| segment.is_a?(Integer) }
        prerelease = segments.drop(release.size)
        release.pop while release.size > 3 && release.last.zero?
        return nil if release.size > 3

        release += [ 0 ] * (3 - release.size)
        Version.parse([ release.join("."), *(prerelease.empty? ? [] : [ prerelease.join(".") ]) ].join("-"))&.to_s
      end
    end

    attr_reader :alternatives

    def initialize(alternatives)
      @alternatives = alternatives.map(&:freeze).freeze
      freeze
    end

    # Whether `value` (a Version or a String) meets every comparator of at
    # least one alternative. false when it doesn't parse.
    def satisfied_by?(value)
      value = self.class.send(:coerce, value)
      return false if value.nil?

      alternatives.any? { |comparators| comparators.all? { |comparator| comparator.satisfied_by?(value) } }
    end

    # The canonical neutral form: ">=1.4.0 <2.0.0 || =0.9.5".
    def to_s
      alternatives.map { |comparators| comparators.join(" ") }.join(" || ")
    end

    def inspect
      "#<#{self.class.name} #{self}>"
    end

    def self.coerce(value)
      Version.parse(value)
    end
    private_class_method :coerce
  end

  # A range of client build numbers (non-negative integers), in the same
  # comparator syntax: `>=120 <200`, `=7 || >=12`. There is no older syntax
  # to translate.
  class BuildRange < VersionRange
    NUMBER = /\A\d+\z/

    class << self
      def parse(text)
        cached(text) { neutral(text) }
      end

      def translate(_text)
        nil
      end

      # A build number from an Integer or a digit string, or nil.
      def number(value)
        case value
        when Integer then value unless value.negative?
        when String, Symbol
          text = value.to_s.strip
          text.to_i if NUMBER.match?(text) && text.length <= Version::MAX_LENGTH
        end
      end

      private

      def noun
        "build range"
      end

      def operand(text)
        number(text)
      end

      def coerce(value)
        number(value)
      end
    end
  end
end
