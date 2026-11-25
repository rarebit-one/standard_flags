module StandardFlags
  # A client version: SemVer 2.0 (`MAJOR.MINOR.PATCH`, an optional
  # `-prerelease` and an ignored `+build`), plus the shorthands `MAJOR.MINOR`
  # and `MAJOR`, whose missing parts are 0. A shorthand takes no prerelease
  # or build suffix.
  #
  #   StandardFlags::Version.parse("1.4.0-beta.2") < StandardFlags::Version.parse("1.4")  # => true
  #   StandardFlags::Version.parse("v1.4")                                                # => nil
  #
  # Surrounding ASCII spaces and tabs are ignored; anything else outside the
  # grammar (other whitespace, non-ASCII bytes, more than 128 characters)
  # doesn't parse. Values that aren't Strings are read through `to_s`, so a
  # Gem::Version or a Float (`1.4`) parses too.
  #
  # Ordering follows SemVer §11: numbers compare by value; a prerelease sorts
  # before its release; prerelease identifiers compare left to right,
  # numeric ones by value and below alphanumeric ones, alphanumeric ones in
  # ASCII order, and a shorter list first when the rest are equal. Build
  # metadata is ignored, so `1.4.0+381 == 1.4.0`. Numbers have no size limit
  # (with no leading zeros, comparing by length and then digit by digit
  # gives the same order, which is how a language without big integers
  # matches).
  class Version
    include Comparable

    NUMBER = /0|[1-9]\d*/
    IDENTIFIER = /0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*/
    PATTERN = /
      \A(?<major>#{NUMBER})
      (?:\.(?<minor>#{NUMBER})
        (?:\.(?<patch>#{NUMBER})
          (?:-(?<prerelease>#{IDENTIFIER}(?:\.#{IDENTIFIER})*))?
          (?:\+(?<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?
        )?
      )?\z
    /x
    # Longest string `parse` reads, so a header can't make it do much work.
    MAX_LENGTH = 128
    # ASCII space and tab, the only blanks ignored around a version.
    BLANKS = [ 32, 9 ].freeze

    attr_reader :major, :minor, :patch, :prerelease, :build

    # The Version for `text`, or nil when it isn't one. Takes a Version too.
    def self.parse(text)
      return text if text.is_a?(Version)

      text = clean(text)
      return nil if text.nil? || text.length > MAX_LENGTH

      match = PATTERN.match(text)
      match && new(match)
    end

    # `value.to_s` without surrounding ASCII spaces and tabs, or nil when it
    # is nil or holds anything but ASCII (invalid UTF-8 included), so
    # nothing downstream can raise on its encoding.
    #
    # @api private
    def self.clean(value)
      return nil if value.nil?

      bytes = value.to_s.b
      return nil unless bytes.ascii_only?

      # A byte scan rather than a regex, so a long run of blanks costs
      # linear time.
      first = 0
      last = bytes.bytesize
      first += 1 while first < last && BLANKS.include?(bytes.getbyte(first))
      last -= 1 while last > first && BLANKS.include?(bytes.getbyte(last - 1))
      bytes.byteslice(first, last - first).force_encoding(Encoding::UTF_8)
    end

    def self.parse!(text)
      parse(text) || raise(ArgumentError, "#{text.inspect} is not a version")
    end

    def initialize(match)
      @major = match[:major].to_i
      @minor = match[:minor].to_i
      @patch = match[:patch].to_i
      @prerelease = match[:prerelease].to_s.split(".").map { |id| id.match?(/\A\d+\z/) ? id.to_i : id.freeze }.freeze
      @build = match[:build]&.freeze
      freeze
    end

    def prerelease?
      !prerelease.empty?
    end

    def <=>(other)
      return nil unless other.is_a?(Version)

      ([ major, minor, patch ] <=> [ other.major, other.minor, other.patch ]).nonzero? ||
        compare_prerelease(other.prerelease)
    end

    def eql?(other)
      other.is_a?(Version) && (self <=> other).zero?
    end

    def hash
      [ self.class, major, minor, patch, prerelease ].hash
    end

    # The full form without build metadata: "1.4.0", "1.4.0-beta.2".
    def to_s
      release = "#{major}.#{minor}.#{patch}"
      prerelease? ? "#{release}-#{prerelease.join('.')}" : release
    end

    def inspect
      "#<StandardFlags::Version #{self}>"
    end

    private

    def compare_prerelease(other)
      return 0 if prerelease.empty? && other.empty?
      return 1 if prerelease.empty?
      return -1 if other.empty?

      prerelease.zip(other).each do |mine, theirs|
        return 1 if theirs.nil?

        order = compare_identifier(mine, theirs)
        return order unless order.zero?
      end
      prerelease.size <=> other.size
    end

    def compare_identifier(mine, theirs)
      case [ mine.is_a?(Integer), theirs.is_a?(Integer) ]
      when [ true, false ] then -1
      when [ false, true ] then 1
      else mine <=> theirs
      end
    end
  end
end
