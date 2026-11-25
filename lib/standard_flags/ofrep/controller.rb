require "active_support/concern"
require "active_support/core_ext/class/attribute"

module StandardFlags
  module OFREP
    # The OFREP endpoints as a controller mixin. The app draws the routes and
    # authenticates the request before they run, exactly as for its own API:
    #
    #   # config/routes.rb
    #   post "ofrep/v1/evaluate/flags", to: "flags#ofrep_evaluate_flags"
    #   post "ofrep/v1/evaluate/flags/:key", to: "flags#ofrep_evaluate_flag"
    #
    #   class FlagsController < Api::BaseController   # ActionController::API
    #     include StandardFlags::OFREP::Controller
    #     standard_flags_ofrep audience: :mobile
    #
    #     private
    #
    #     def standard_flags_context = current_account
    #   end
    #
    # On an ActionController::Base controller with forgery protection, say
    # how the endpoints treat it: `csrf: :skip` (skip it for these two
    # actions; safe because they only accept `Content-Type: application/json`,
    # which a cross-site form can't send without a CORS preflight, and right
    # for bearer-token APIs) or `csrf: :protect` (keep Rails' check; the
    # client sends the token). Leaving it out raises
    # StandardFlags::ConfigurationError, when the class is declared or on
    # the first request, instead of answering every request 422.
    #
    # * Units come from `standard_flags_context` (the authenticated caller),
    #   never from the body: its `targetingKey` is ignored. The body only adds
    #   client attributes (`platform`, `appVersion` / `app_version`,
    #   `build`), and an X-Client-* header wins over the same attribute in the
    #   body. With `config.read_client_headers` off, the request contributes
    #   no client at all.
    # * The bulk endpoint answers `{ "flags": [...], "metadata": { "version":
    #   <etag> } }` with an ETag; If-None-Match naming it gets 304 and no
    #   body. Both endpoints send `Cache-Control: no-cache, private` and a
    #   Vary on Authorization and the client headers. A single-flag 200 also
    #   carries a strong ETag over its one entry, and honours If-None-Match.
    # * Before anything else runs (Rails' parameter parsing, the app's
    #   filters, forgery protection), the mixin checks the request itself: a
    #   Content-Type other than application/json gets 415, and a body over
    #   OFREP::MAX_BODY_BYTES (read with a bounded read), not UTF-8, not JSON
    #   or not an evaluation request gets 400, both in OFREP's error shape
    #   (INVALID_CONTEXT). These answers come before authentication and say
    #   nothing about the caller. An app's `rescue_from StandardError` can't
    #   turn them into 5xx.
    # * A flag the audience isn't told about, or whose min_client: the client
    #   doesn't meet, gets 404 FLAG_NOT_FOUND, so server-only keys stay
    #   invisible; one whose evaluation failed gets 400 with its error code.
    #   401 and 403 stay the app's. Nothing answers 5xx on purpose.
    #
    # `standard_flags_ofrep audience: :pre_auth, anonymous: true` serves a
    # controller with no authentication: only a `public: true` audience (see
    # StandardFlags::Audience), evaluated with no actors and without calling
    # `standard_flags_context`; the body's `targetingKey` becomes the key of
    # the audience's `unit:`, when it declares one.
    module Controller
      extend ActiveSupport::Concern
      include StandardFlags::Controller

      ACTIONS = %w[ofrep_evaluate_flags ofrep_evaluate_flag].freeze
      CSRF_CHOICES = [ nil, :skip, :protect ].freeze
      # Longest key looked up; a longer one is a 404 without a lookup.
      MAX_KEY_LENGTH = 256
      # Longest requested key echoed back in an error.
      MAX_KEY_ECHO = 200

      included do
        class_attribute :standard_flags_ofrep_options, instance_writer: false, default: nil
      end

      class_methods do
        def standard_flags_ofrep(audience:, anonymous: false, csrf: nil)
          raise ArgumentError, "anonymous: must be true or false" unless [ true, false ].include?(anonymous)
          raise ArgumentError, "csrf: must be :skip or :protect" unless CSRF_CHOICES.include?(csrf)

          self.standard_flags_ofrep_options = { audience: audience.to_sym, anonymous: anonymous, csrf: csrf }.freeze
          wrap_parameters false if respond_to?(:wrap_parameters)
          skip_forgery_protection(only: ACTIONS.map(&:to_sym)) if csrf == :skip && respond_to?(:skip_forgery_protection)
          standard_flags_ofrep_check_csrf!
        end

        # Whether Rails' forgery protection runs before this controller's
        # actions (whatever `allow_forgery_protection` says right now).
        def standard_flags_forgery_protected?
          respond_to?(:_process_action_callbacks) &&
            _process_action_callbacks.any? { |callback| callback.filter == :verify_authenticity_token }
        end

        def standard_flags_ofrep_check_csrf!
          options = standard_flags_ofrep_options
          return if options.nil? || !options[:csrf].nil? || !standard_flags_forgery_protected?

          raise ConfigurationError,
            "#{name || 'this controller'} has forgery protection: declare `standard_flags_ofrep ..., csrf: :skip` " \
            "(bearer-token APIs; the endpoints accept only application/json) or `csrf: :protect` (clients send the " \
            "CSRF token)"
        end
      end

      # POST /ofrep/v1/evaluate/flags
      def ofrep_evaluate_flags
        result = standard_flags_ofrep_result(standard_flags_ofrep_request)
        standard_flags_ofrep_headers(result.etag_header)
        if result.fresh?(request.headers["If-None-Match"])
          head :not_modified
        else
          render json: result.to_h
        end
      end

      # POST /ofrep/v1/evaluate/flags/:key, where :key is a wire name.
      def ofrep_evaluate_flag
        key = request.path_parameters[:key].to_s
        result = standard_flags_ofrep_result(standard_flags_ofrep_request, only: key) if key.length <= MAX_KEY_LENGTH
        entry = result&.[](key)
        if entry.nil?
          standard_flags_ofrep_headers
          echo = key[0, MAX_KEY_ECHO]
          render json: { key: echo, errorCode: ErrorCode::FLAG_NOT_FOUND, errorDetails: "flag #{echo} was not found" },
                 status: :not_found
        elsif entry.error?
          standard_flags_ofrep_headers
          render json: entry.to_h, status: :bad_request
        else
          standard_flags_ofrep_single(result, entry)
        end
      end

      # Checks the request before Rails' instrumentation (which decodes a
      # JSON body), the app's filters and forgery protection run, and answers
      # a bad one itself, outside the rescue chain.
      def process_action(*)
        return super unless ACTIONS.include?(action_name.to_s)

        self.class.standard_flags_ofrep_check_csrf!
        @standard_flags_ofrep_request = OFREP.read(request)
        super
      rescue OFREP::InvalidRequest, OFREP::UnsupportedMediaType => e
        raise unless @standard_flags_ofrep_request.nil?

        standard_flags_ofrep_refuse(e)
      end

      private

      # A deliberate strong ETag over the one entry (so Rack::ETag adds no
      # weak one), with If-None-Match honoured as on the bulk endpoint.
      def standard_flags_ofrep_single(result, entry)
        etag = Delivery::Result.new(audience: result.audience, entries: [ entry ].freeze,
                                    etag: Delivery.etag(result.audience, [ entry ]))
        standard_flags_ofrep_headers(etag.etag_header)
        etag.fresh?(request.headers["If-None-Match"]) ? head(:not_modified) : render(json: entry.to_h)
      end

      def standard_flags_ofrep_request
        @standard_flags_ofrep_request or raise Error, "#{self.class.name}: the OFREP request was not read"
      end

      def standard_flags_ofrep_result(parsed, only: nil)
        options = standard_flags_ofrep_options
        raise Error, "#{self.class.name} needs `standard_flags_ofrep audience: ...`" unless options

        client = standard_flags_ofrep_client(parsed.client)
        if options[:anonymous]
          Delivery.build_anonymous(options[:audience], client: client, targeting_key: parsed.targeting_key, only: only)
        else
          context = Context.wrap(standard_flags_context)
          context = context.with_client(client) if context.client.empty?
          Delivery.build(options[:audience], context, only: only)
        end
      end

      # The request's X-Client-* headers, with body attributes filling the
      # fields the headers don't carry; nothing at all when
      # `config.read_client_headers` is off.
      def standard_flags_ofrep_client(body_client)
        return Client.empty unless StandardFlags.config.read_client_headers

        merged = body_client.to_h.merge(standard_flags_client.to_h)
        merged.empty? ? Client.empty : Client.new(**merged)
      end

      def standard_flags_ofrep_headers(etag = nil)
        response.headers["ETag"] = etag if etag
        # Through Rails' own Cache-Control handling, which would rewrite a
        # raw "private, no-cache" header to "no-cache": this gives
        # "no-cache, private".
        response.cache_control.merge!(no_cache: true, extras: [ "private" ])
        vary = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        vary += [ "Authorization", *StandardFlags.config.client_headers.values.compact.map(&:to_s) ]
        response.headers["Vary"] = vary.uniq(&:downcase).join(", ")
      end

      def standard_flags_ofrep_refuse(exception)
        body = { errorCode: ErrorCode::INVALID_CONTEXT, errorDetails: exception.message }
        key = request.path_parameters[:key]
        body = { key: key.to_s[0, MAX_KEY_ECHO] }.merge(body) if key
        standard_flags_ofrep_headers
        # Set directly rather than through `render`, whose Vary handling
        # reads params, which would parse the body being refused.
        self.status = exception.is_a?(OFREP::UnsupportedMediaType) ? 415 : 400
        self.content_type = "application/json"
        self.response_body = JSON.generate(body)
      end
    end
  end
end
