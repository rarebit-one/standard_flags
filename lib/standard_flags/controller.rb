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
      helper_method :standard_flags_payload if respond_to?(:helper_method)
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
      StandardFlags.payload(audience, for: standard_flags_context)
    end

    private

    # Override to say who flags are evaluated for in this controller.
    def standard_flags_context
      nil
    end

    def standard_flags_require!(key, error:, status:, responder: nil)
      return if StandardFlags.reader(for: standard_flags_context).enabled?(key)

      denial = Denial.new(key: key.to_sym, error: error, status: status, feature: standard_flags_feature_name(key))
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
      definition = StandardFlags.registry[key]
      return key.to_s unless definition

      definition.wire_name(StandardFlags.config.default_audience) || definition.expose.values.first || key.to_s
    end
  end
end
