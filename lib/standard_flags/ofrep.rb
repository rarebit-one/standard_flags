require "json"

module StandardFlags
  # OpenFeature Remote Evaluation Protocol (OFREP) support: the request
  # side. StandardFlags::Delivery builds the responses, and
  # StandardFlags::OFREP::Controller (actionpack) serves them.
  #
  # Validated against the OFREP OpenAPI document 0.4.0
  # (open-feature/protocol, service/openapi.yaml at 98c4e0de55).
  module OFREP
    autoload :Controller, "standard_flags/ofrep/controller"

    # Longest request body read, in bytes.
    MAX_BODY_BYTES = 64 * 1024
    # Longest `targetingKey` an anonymous request may name.
    MAX_TARGETING_KEY = 256

    # The one media type the endpoints accept (any charset parameter).
    MEDIA_TYPE = "application/json".freeze

    # A body OFREP can't accept. The message is safe to return to the client.
    class InvalidRequest < Error; end

    # A request whose Content-Type isn't application/json (answered 415).
    class UnsupportedMediaType < Error; end

    # What a request body says: the client attributes it carries, and its
    # `targetingKey` (used only before authentication, for a public
    # audience's unit).
    Request = Data.define(:client, :targeting_key)

    module_function

    # Reads and parses a Rack request's evaluation body before Rails
    # touches it: the Content-Type must be application/json, and at most
    # MAX_BODY_BYTES are read (a declared Content-Length over the limit is
    # refused without reading). The bytes read become the request's
    # RAW_POST_DATA, so Rails' own parameter parsing, if anything asks for
    # it later, sees the same (already checked) body.
    def read(request)
      unless request.media_type.to_s.downcase == MEDIA_TYPE
        raise UnsupportedMediaType, "Content-Type must be #{MEDIA_TYPE}"
      end

      length = request.content_length.to_i
      raise InvalidRequest, too_large if length > MAX_BODY_BYTES

      body = bounded_body(request)
      raise InvalidRequest, too_large if body.bytesize > MAX_BODY_BYTES

      request.set_header("RAW_POST_DATA", body)
      parse(body)
    end

    def bounded_body(request)
      io = request.get_header("rack.input")
      return "".b if io.nil?

      io.rewind if io.respond_to?(:rewind)
      body = io.read(MAX_BODY_BYTES + 1) || "".b
      io.rewind if io.respond_to?(:rewind)
      body
    end

    def too_large
      "the request body is larger than #{MAX_BODY_BYTES} bytes"
    end

    # Parses an evaluation request body (`{ "context": { ... } }`). Raises
    # InvalidRequest for anything that isn't one. Client attributes
    # (`platform`, `appVersion` / `app_version`, `build`) are checked like
    # the X-Client-* headers: a value that fails is dropped, not refused.
    def parse(body)
      body = body.to_s.dup.force_encoding(Encoding::UTF_8)
      raise InvalidRequest, too_large if body.bytesize > MAX_BODY_BYTES
      raise InvalidRequest, "the request body is not valid UTF-8" unless body.valid_encoding?

      document = parse_json(body)
      context = document["context"] if document.is_a?(Hash)
      raise InvalidRequest, "the request body must be a JSON object with a context object" unless context.is_a?(Hash)

      Request.new(client: Client.from_context(check_fields!(context)), targeting_key: targeting_key(context))
    end

    def parse_json(body)
      JSON.parse(body)
    rescue JSON::ParserError
      raise InvalidRequest, "the request body is not valid JSON"
    end

    # Checks the property each client field is read from (the first one
    # present, as Client.from_context reads it).
    def check_fields!(context)
      Client::CONTEXT_FIELDS.each do |field, names|
        name = names.find { |candidate| !context[candidate].nil? }
        next if name.nil?

        value = context[name]
        next if value.is_a?(String) || (field == :build && value.is_a?(Integer))

        raise InvalidRequest, "context property '#{name}' must be a string"
      end
      context
    end

    def targeting_key(context)
      value = context["targetingKey"]
      return nil if value.nil?
      raise InvalidRequest, "context property 'targetingKey' must be a string" unless value.is_a?(String)
      raise InvalidRequest, "context property 'targetingKey' is longer than #{MAX_TARGETING_KEY} characters" if value.length > MAX_TARGETING_KEY

      value.strip.empty? ? nil : value
    end
  end
end
