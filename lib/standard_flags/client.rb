module StandardFlags
  # The calling client: platform, version and build. Immutable.
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
  # parse as a StandardFlags::Version; the build must be a non-negative
  # integer. A value that fails is dropped, as if the header were missing,
  # and emits `client_invalid.standard_flags`; nothing raises, and nothing is
  # reported as an error. A request with none of the headers gives an empty
  # client, which rules treat as an unknown build.
  #
  # `Client.new(platform: "ios", version: "2.1.0")` (or a Context's
  # `client:` Hash) keeps whatever it is given, the way 0.2.2 did: `[]`,
  # `to_h` and the memo key see the given values, and the typed readers
  # parse them (platform downcased, version as a Version or nil, build as an
  # Integer or nil) with no allowlist and no notification. Other keys are
  # kept too.
  class Client
    FIELDS = %i[platform version build].freeze
    # Longest header value read.
    MAX_LENGTH = 128

    attr_reader :platform, :version, :build

    class << self
      def empty
        @empty ||= new
      end

      # A Client from a Client, a Hash of attributes, or nil (empty).
      def wrap(value)
        case value
        when Client then value
        when nil then empty
        when Hash then value.empty? ? empty : new(**value.transform_keys(&:to_sym))
        else raise ArgumentError, "client: must be a StandardFlags::Client or a Hash, not a #{value.class}"
        end
      end

      # The client a request's headers describe. Takes anything that answers
      # `[]` with a header name: ActionDispatch's headers, a Rack env (read
      # as HTTP_X_CLIENT_PLATFORM and so on) or a plain Hash.
      def from_headers(headers)
        config = StandardFlags.config
        names = config.client_headers
        attributes = FIELDS.each_with_object({}) do |field, found|
          name = names[field]
          raw = name && header(headers, name.to_s)
          next if raw.nil? || raw.to_s.strip.empty?

          value = normalize(field, raw.to_s.strip, config)
          if value.nil?
            Reporting.instrument(:client_invalid, field: field, header: name.to_s)
          else
            found[field] = value
          end
        end
        attributes.empty? ? empty : new(**attributes)
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
          platform if config.client_platforms.map { |name| name.to_s.downcase }.include?(platform)
        when :version then value if Version.parse(value)
        when :build then value if BuildRange.number(value)
        end
      end
    end

    def initialize(**attributes)
      @attributes = attributes.transform_keys(&:to_sym).freeze
      @platform = present(@attributes[:platform])&.downcase&.freeze
      @version = Version.parse(@attributes[:version])
      @build = BuildRange.number(@attributes[:build])
      freeze
    end

    # The value as given, by field name.
    def [](field)
      @attributes[field.to_sym]
    end

    def to_h
      @attributes
    end

    def empty?
      @attributes.empty?
    end

    # Equal to another Client with the same attributes, or to the Hash of
    # them (so `context.client == { platform: "ios" }` still reads true).
    def ==(other)
      case other
      when Client then to_h == other.to_h
      when Hash then to_h == other.transform_keys(&:to_sym)
      else false
      end
    end

    def eql?(other)
      other.is_a?(Client) && to_h.eql?(other.to_h)
    end

    def hash
      [ self.class, @attributes ].hash
    end

    def inspect
      "#<StandardFlags::Client #{@attributes.map { |k, v| "#{k}=#{v.inspect}" }.join(' ')}>"
    end

    private

    def present(value)
      text = value.to_s.strip unless value.nil?
      text unless text.nil? || text.empty?
    end
  end
end
