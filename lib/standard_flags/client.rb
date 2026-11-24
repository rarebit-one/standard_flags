module StandardFlags
  # The calling client: platform, version and build. A frozen Hash of the
  # attributes as given (so `fetch`, `dig`, `key?`, `each` and `to_h` work as
  # they did on 0.2.2's client Hash), plus typed readers:
  #
  #   client = StandardFlags::Client.from_headers(request.headers)
  #   client.platform  # => "android"
  #   client.version   # => #<StandardFlags::Version 1.4.0>
  #   client.build     # => 381
  #   client[:version] # => "1.4.0" (as received)
  #
  # `from_headers` reads `X-Client-Platform`, `X-Client-Version` and
  # `X-Client-Build` (the names are `config.client_headers`). The platform is
  # downcased and must be one of `config.client_platforms`; the version must
  # parse as a StandardFlags::Version; the build must be 1 to 18 digits. A
  # version or build that fails is dropped, as if the header were missing; a
  # platform that fails becomes "unknown" (below). Either way it emits
  # `client_invalid.standard_flags`; nothing raises, whatever bytes arrive,
  # and nothing is reported as an error. A request with none of the headers
  # gives an empty client.
  #
  # Runtime rules scope version and build ranges to a platform. An empty
  # client (no platform) fails a rule's platform list but skips its
  # per-platform ranges, as in 0.2.2. A client whose platform is "unknown"
  # (sent but not recognised) fails every platform-scoped condition: the
  # platform list and every version or build range. So a misspelt platform
  # header can't step around a version floor.
  #
  # `Client.new(platform: "ios", version: "2.1.0")` (or a Context's
  # `client:` Hash) keeps whatever it is given, the way 0.2.2 did, other keys
  # included. The typed readers parse it with no allowlist and no
  # notification: platform stripped and downcased, version as a Version (via
  # `to_s`) or nil, build as an Integer or nil.
  class Client < Hash
    FIELDS = %i[platform version build].freeze
    # The platform of a client that sent one this app doesn't recognise.
    UNKNOWN_PLATFORM = "unknown".freeze
    # Longest header value read.
    MAX_LENGTH = 128

    class << self
      def empty
        @empty ||= new
      end

      def [](*arguments)
        new(Hash[*arguments])
      end

      # A Client from a Client, a Hash of attributes, or nil (empty).
      def wrap(value)
        case value
        when Client then value
        when nil then empty
        when Hash then value.empty? ? empty : new(value)
        else raise ArgumentError, "client: must be a StandardFlags::Client or a Hash, not a #{value.class}"
        end
      end

      # The client a request's headers describe. Takes anything that answers
      # `[]` with a header name: ActionDispatch's headers, a Rack env (read
      # as HTTP_X_CLIENT_PLATFORM and so on) or a plain Hash.
      def from_headers(headers)
        config = StandardFlags.config
        attributes = FIELDS.each_with_object({}) do |field, found|
          name = config.client_headers[field]&.to_s
          raw = name && header(headers, name)
          next if raw.nil?

          text = Version.clean(raw)
          next if text&.empty?

          value = text && normalize(field, text, config)
          next found[field] = value unless value.nil?

          Reporting.instrument(:client_invalid, field: field, header: name)
          found[field] = UNKNOWN_PLATFORM if field == :platform
        end
        attributes.empty? ? empty : new(attributes)
      end

      private

      def header(headers, name)
        [ name, name.downcase, "HTTP_#{name.upcase.tr('-', '_')}" ].each do |candidate|
          value = headers[candidate]
          return value unless value.nil?
        end
        nil
      rescue StandardError
        nil
      end

      def normalize(field, value, config)
        return nil if value.length > MAX_LENGTH

        case field
        when :platform
          platform = value.downcase
          allowed = config.client_platforms.map { |name| name.to_s.downcase } - [ UNKNOWN_PLATFORM ]
          platform if allowed.include?(platform)
        when :version then value if Version.parse(value)
        when :build then value if BuildRange.number(value)
        end
      end
    end

    def initialize(attributes = nil, **keywords)
      super()
      (attributes || {}).to_h.merge(keywords).each { |key, value| store(key.to_sym, value) }
      freeze
    end

    # The platform, stripped and downcased, or nil when there is none or it
    # is "unknown".
    def platform
      text = Version.clean(self[:platform])&.downcase
      text unless text.nil? || text.empty? || text == UNKNOWN_PLATFORM
    end

    # Whether the client sent a platform that isn't recognised.
    def unknown_platform?
      Version.clean(self[:platform])&.downcase == UNKNOWN_PLATFORM
    end

    def version
      Version.parse(self[:version])
    end

    def build
      BuildRange.number(self[:build])
    end
  end
end
