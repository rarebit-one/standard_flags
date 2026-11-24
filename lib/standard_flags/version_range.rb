module StandardFlags
  # A range of client versions, in a syntax the Kotlin and TypeScript
  # clients share: comparators (`>=`, `>`, `<=`, `<`, `=`) separated by
  # spaces, all of which must hold, with optional `||` alternatives.
  # Whitespace between an operator and its version is optional, and versions
  # take the shorthands StandardFlags::Version reads. Whitespace means ASCII
  # spaces and tabs only, and a range is at most 1024 characters.
  #
  #   range = StandardFlags::VersionRange.parse(">=1.4.0 <2.0.0 || =0.9.5-beta.1")
  #   range.satisfied_by?("1.9.3")         # => true
  #   range.to_s                           # => ">=1.4.0 <2.0.0 || =0.9.5-beta.1"
  #
  # Comparison is plain SemVer ordering, nothing more: `<2.0.0` admits
  # `2.0.0-beta.1`, which sorts before `2.0.0`, and a shorthand is an exact
  # version, not a wildcard (`>1.4` admits `1.4.1`; `<=1.4` excludes
  # `1.4.5`). A version that doesn't parse satisfies no neutral range.
  #
  # Ranges stored by 0.2.x are RubyGems requirements (`">= 1.4.0"`,
  # `"~> 1.4"`, `">= 1.4, < 2"`), and `parse` keeps reading the ones only
  # RubyGems can read exactly as RubyGems does. Where one has a neutral
  # equivalent it is translated:
  # `~> 1.4` reads as `>=1.4.0 <2.0.0-0`, `~> 1.4.2` as `>=1.4.2 <1.5.0-0`,
  # `!= 1.5` as `<1.5.0 || >1.5.0`. The `-0` is the lowest prerelease SemVer
  # allows, so `<2.0.0-0` excludes `2.0.0-beta.1` too, as RubyGems' `~>`
  # (which compares the release part only) does. A requirement the neutral
  # syntax can't express (`>= 1.4.0.1`, or any prerelease operand such as
  # `>= 1.4.0.beta`, which RubyGems orders differently) is still evaluated
  # with Gem::Requirement, and so is any range RubyGems can read when the
  # client version isn't SemVer (`1.4.0.1`, `1.4.0.beta`), as 0.2.2 did. A
  # string valid in both syntaxes (`>= 1.4.0`, `>= 1.0.0-alpha`) is neutral:
  # a SemVer client version is compared by SemVer. Only the neutral syntax
  # is portable; the write path stores it when it can.
  class VersionRange
    class Invalid < StandardFlags::Error; end

    COMPARATOR = /(>=|<=|>|<|=)[ \t]*([^ \t<>=|]+)/
    ALTERNATIVE = /\A[ \t]*#{COMPARATOR}(?:[ \t]+#{COMPARATOR})*[ \t]*\z/
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
        cached(text) do
          range = neutral(text)
          requirement = requirement(text)
          if range
            requirement ? new(range.alternatives, requirement: requirement) : range
          elsif requirement
            new(translated(text), requirement: requirement, source: text.to_s)
          end
        end
      end

      def parse!(text)
        parse(text) || raise(Invalid, "#{text.inspect} is not a #{noun}")
      end

      def valid?(text)
        !parse(text).nil?
      end

      # The range for `text` in the neutral syntax only, or nil. It compares
      # SemVer only, as clients do.
      def neutral(text)
        text = clean(text)
        return nil if text.nil? || text.length > MAX_LENGTH

        alternatives = text.split("||", -1).map { |alternative| comparators(alternative) }
        new(alternatives) if alternatives.any? && alternatives.all?
      end

      # The neutral form of a RubyGems requirement (comma-joined), or nil
      # when it isn't one, or is one the neutral syntax can't express.
      def translate(text)
        alternatives = requirement(text) && translated(text)
        alternatives && new(alternatives).to_s
      end

      private

      def noun
        "version range"
      end

      def clean(text)
        return nil unless text.is_a?(String) || text.is_a?(Symbol)

        Version.clean(text)
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

      def terms(text)
        text = clean(text)
        return nil if text.nil? || text.length > MAX_LENGTH

        terms = text.split(",").map(&:strip)
        terms.empty? ? [ ">= 0" ] : terms # RubyGems' default requirement
      end

      # The Gem::Requirement for a comma-joined RubyGems requirement, or nil.
      def requirement(text)
        list = terms(text)
        list && Gem::Requirement.new(*list)
      rescue Gem::Requirement::BadRequirementError, ArgumentError
        nil
      end

      # The neutral alternatives a RubyGems requirement means, or nil when
      # the neutral syntax can't hold it.
      def translated(text)
        options = terms(text).map { |term| legacy_term(term) }
        return nil if options.any?(&:nil?)

        combined = options.reduce([ [] ]) do |alternatives, choices|
          alternatives.product(choices).map { |left, right| left + right }
        end
        return nil if combined.size > MAX_ALTERNATIVES

        neutral(combined.map { |alternative| alternative.join(" ") }.join(" || "))&.alternatives
      end

      # The alternatives (each a list of comparator strings) one RubyGems
      # term means, or nil when SemVer can't say the same: a prerelease
      # operand, which RubyGems orders differently (it reads a client's
      # `1.4.0-beta` as `1.4.0.pre.beta`), or more than three release
      # segments.
      def legacy_term(term)
        match = Gem::Requirement::PATTERN.match(term)
        return nil if Gem::Version.new(match[2]).prerelease?

        operator = match[1] || "="
        version = legacy_version(match[2])
        return nil unless version

        case operator
        when "~>"
          upper = legacy_version(Gem::Version.new(match[2]).bump.to_s)
          upper && [ [ ">=#{version}", "<#{upper}-0" ] ]
        when "!=" then [ [ "<#{version}" ], [ ">#{version}" ] ]
        else [ [ "#{operator}#{version}" ] ]
        end
      end

      # A RubyGems release version as SemVer: "1.4" → "1.4.0", "1.4.0.0" →
      # "1.4.0". nil past three non-zero release segments, which SemVer
      # can't hold.
      def legacy_version(text)
        release = Gem::Version.new(text).segments
        release.pop while release.size > 3 && release.last.zero?
        return nil if release.size > 3

        Version.parse((release + ([ 0 ] * (3 - release.size))).join("."))&.to_s
      end
    end

    # The neutral alternatives, or nil for a RubyGems requirement the
    # neutral syntax can't express. The Gem::Requirement, when the range is
    # also RubyGems syntax.
    attr_reader :alternatives, :requirement

    def initialize(alternatives, requirement: nil, source: nil)
      @alternatives = alternatives&.map(&:freeze)&.freeze
      @requirement = requirement
      @source = source&.dup&.freeze
      freeze
    end

    # Whether `value` (a Version, a String, or anything whose `to_s` is one)
    # meets every comparator of at least one alternative. A SemVer value is
    # compared by SemVer; any other value meets the range only through
    # RubyGems, when the range is RubyGems syntax.
    def satisfied_by?(value)
      version = Version.parse(value)
      return alternatives_met?(version) if version && alternatives

      gem_version = gem_version(value)
      !gem_version.nil? && !requirement.nil? && requirement.satisfied_by?(gem_version)
    end

    # Whether this was read as a RubyGems requirement rather than the
    # neutral syntax.
    def legacy?
      !@source.nil?
    end

    # The canonical neutral form (">=1.4.0 <2.0.0 || =0.9.5"), or the stored
    # text of a RubyGems requirement the neutral syntax can't express.
    def to_s
      return @source unless alternatives

      alternatives.map { |comparators| comparators.join(" ") }.join(" || ")
    end

    def inspect
      "#<#{self.class.name} #{self}>"
    end

    private

    def alternatives_met?(version)
      alternatives.any? { |comparators| comparators.all? { |comparator| comparator.satisfied_by?(version) } }
    end

    def gem_version(value)
      text = Version.clean(value)
      return nil if text.nil? || text.empty? || !Gem::Version.correct?(text)

      Gem::Version.new(text)
    end
  end

  # A range of client build numbers, in the same comparator syntax:
  # `>=120 <200`, `=7 || >=12`. A build number is 1 to 18 ASCII digits (so
  # it fits a signed 64-bit integer); leading zeros are allowed and ignored,
  # signs are not. There is no older syntax to translate.
  class BuildRange < VersionRange
    NUMBER = /\A\d{1,18}\z/

    class << self
      def parse(text)
        cached(text) { neutral(text) }
      end

      def translate(_text)
        nil
      end

      # A build number from a non-negative Integer below 10**18 or a digit
      # string, or nil.
      def number(value)
        case value
        when Integer then value if value >= 0 && value < 10**18
        when String, Symbol
          text = Version.clean(value)
          text.to_i if text && NUMBER.match?(text)
        end
      end

      private

      def noun
        "build range"
      end

      def operand(text)
        number(text)
      end
    end

    def satisfied_by?(value)
      build = self.class.number(value)
      !build.nil? && alternatives.any? { |comparators| comparators.all? { |comparator| comparator.satisfied_by?(build) } }
    end
  end
end
