require "active_support/concern"

module StandardFlags
  # Controller guards and the payload helper.
  #
  #   class ApplicationController < ActionController::Base
  #     include StandardFlags::Controller
  #
  #     inertia_share features: -> { standard_flags_payload(:web) }
  #
  #     private
  #
  #     def standard_flags_context = Current.account
  #   end
  #
  #   class ReportsController < ApplicationController
  #     requires_flag :new_reports, except: :index
  #     requires_flag :legacy_export, error: :not_found   # keep a 404 contract
  #     requires_flag :report_api, with: :render_api_error # keep this endpoint's own error shape
  #   end
  #
  # A JSON request that hits a disabled flag gets one JSON:API error:
  #
  #   {"errors":[{"status":"403","code":"feature_disabled","meta":{"feature":"new_reports"}}]}
  #
  # `meta.feature` is the flag's wire name for `config.default_audience` when
  # it has one, else the key. `error: :not_found` answers 404 with no meta,
  # so it reveals nothing. Other formats get the bare status.
  # `config.controller_responder` replaces the response entirely, and a
  # guard's own `with:` (a callable or the name of a controller method)
  # replaces it for that guard only.
  #
  # A StandardFlags::FeatureDisabled raised in an action (or by
  # `StandardFlags.require!`) is answered the same way, through
  # `config.controller_responder` or the default response, even when the
  # app declares `rescue_from StandardError` after including this module.
  # Only an app's own `rescue_from StandardFlags::FeatureDisabled` (or a
  # subclass) takes it over. One raised with `status: 404` answers like
  # `error: :not_found`, with no meta.
  #
  # Flags are evaluated for `standard_flags_context` plus the calling client,
  # read once per request from the X-Client-Platform, X-Client-Version and
  # X-Client-Build headers (`standard_flags_client`). A context that already
  # carries a client keeps it. `config.read_client_headers = false` turns
  # the headers off. Inside an action, `standard_flags_reader` (or
  # `StandardFlags.require!(key, for: standard_flags_request_context)`)
  # evaluates for the same context the guards use.
  module Controller
    extend ActiveSupport::Concern

    ERRORS = { feature_disabled: 403, not_found: 404 }.freeze

    # What a guard hands the responder.
    Denial = Data.define(:key, :error, :status, :feature) do
      def body
        error_object = { status: status.to_s, code: error.to_s }
        error_object[:meta] = { feature: feature } if error == :feature_disabled
        { errors: [ error_object ] }
      end
    end

    included do
      if respond_to?(:helper_method)
        helper_method :standard_flags_payload, :standard_flags_client, :standard_flags_request_context, :standard_flags_reader
      end
      rescue_from FeatureDisabled, with: :standard_flags_feature_disabled if respond_to?(:rescue_from)
    end

    class_methods do
      # `with:` answers a denial for this guard only, instead of
      # `config.controller_responder` or the default response: a callable
      # taking `(controller, denial)`, or a Symbol naming a controller method
      # that takes `(denial)`. It must render or redirect to halt the action.
      def requires_flag(key, only: nil, except: nil, error: :feature_disabled, status: nil, with: nil)
        raise ArgumentError, "error: must be one of #{ERRORS.keys.inspect}" unless ERRORS.key?(error)
        unless with.nil? || with.is_a?(Symbol) || with.respond_to?(:call)
          raise ArgumentError, "with: must respond to call(controller, denial) or be a Symbol naming a controller method"
        end

        status ||= ERRORS.fetch(error)
        before_action(**{ only: only, except: except }.compact) do
          standard_flags_require!(key, error: error, status: status, responder: with)
        end
      end
    end

    # The payload for one audience, evaluated for this request's context.
    def standard_flags_payload(audience)
      StandardFlags.payload(audience, for: standard_flags_request_context)
    end

    private

    # Override to say who flags are evaluated for in this controller.
    def standard_flags_context
      nil
    end

    # The calling client, from this request's headers (memoised). Empty
    # when `config.read_client_headers` is false, no header is sent, or the
    # controller has no request (a console or a spec).
    def standard_flags_client
      @standard_flags_client ||=
        if StandardFlags.config.read_client_headers && request
          Client.from_headers(request.headers)
        else
          Client.empty
        end
    end

    # `standard_flags_context`, with the request's client unless it already
    # names one: what guards and the payload evaluate for.
    def standard_flags_request_context
      context = Context.wrap(standard_flags_context)
      context.client.empty? ? context.with_client(standard_flags_client) : context
    end

    # A reader for this request's context, for reads inside an action:
    # `standard_flags_reader.on?(:new_checkout)`.
    def standard_flags_reader
      StandardFlags.reader(for: standard_flags_request_context)
    end

    # FeatureDisabled is answered here even when an app `rescue_from`
    # (StandardError, say) declared after the include would otherwise win,
    # since Rails tries handlers last-declared first.
    def rescue_with_handler(exception)
      handler = standard_flags_handler(exception)
      return super unless handler

      handler.call(exception)
      exception
    end

    def handler_for_rescue(exception)
      standard_flags_handler(exception) || super
    end
    public :rescue_with_handler, :handler_for_rescue

    def standard_flags_handler(exception)
      return unless exception.is_a?(FeatureDisabled)

      targeted = self.class.rescue_handlers.any? do |name, handler|
        klass = name.safe_constantize if handler != :standard_flags_feature_disabled
        klass.is_a?(Class) && klass <= FeatureDisabled
      end
      method(:standard_flags_feature_disabled) unless targeted
    end

    def standard_flags_require!(key, error:, status:, responder: nil)
      return if StandardFlags.reader(for: standard_flags_request_context).enabled?(key)

      standard_flags_deny(Denial.new(key: key.to_sym, error: error, status: status, feature: standard_flags_feature_name(key)),
                          responder)
    end

    # A 404 answers like `error: :not_found`, revealing no feature name.
    # Nothing is rendered when the action already has.
    def standard_flags_feature_disabled(exception)
      return if performed?

      error = exception.status == ERRORS[:not_found] ? :not_found : :feature_disabled
      standard_flags_deny(Denial.new(key: exception.key, error: error, status: exception.status, feature: exception.feature), nil)
    end

    def standard_flags_deny(denial, responder)
      responder ||= StandardFlags.config.controller_responder
      case responder
      when nil then standard_flags_render_denial(denial)
      when Symbol then send(responder, denial)
      else responder.call(self, denial)
      end
    end

    def standard_flags_render_denial(denial)
      if request.format.json? || request.content_mime_type&.json?
        render json: denial.body, status: denial.status
      else
        head denial.status
      end
    end

    def standard_flags_feature_name(key)
      FeatureDisabled.feature_name(key)
    end
  end
end
