require "active_support/concern"
require "active_support/core_ext/class/attribute"

module StandardFlags
  module ClientStatus
    # `GET /client/status` as a controller mixin. It runs before
    # authentication: it reads only the X-Client-* headers, never
    # `standard_flags_context`, and says nothing about the caller.
    #
    #   # config/routes.rb
    #   get "client/status", to: "client_status#client_status"
    #
    #   class ClientStatusController < ActionController::API   # or ActionController::Base
    #     include StandardFlags::ClientStatus::Controller
    #     standard_flags_client_status                           # group: :driver for a second app
    #   end
    #
    # It answers 200 with StandardFlags::ClientStatus's payload, whatever
    # the status (`upgrade_required` included: the app decides how to show
    # it), with `Cache-Control: max-age=60, private` (the age is `max_age:`)
    # and a Vary on the client headers. It is a GET, so forgery protection
    # never applies. With `config.read_client_headers` off it can't see the
    # client and answers `unknown`.
    module Controller
      extend ActiveSupport::Concern
      include StandardFlags::Controller

      DEFAULT_MAX_AGE = 60

      included do
        class_attribute :standard_flags_client_status_options, instance_writer: false,
                        default: { group: nil, max_age: DEFAULT_MAX_AGE }.freeze
      end

      class_methods do
        def standard_flags_client_status(group: nil, max_age: DEFAULT_MAX_AGE)
          raise ArgumentError, "max_age: must be a non-negative Integer of seconds" unless max_age.is_a?(Integer) && max_age >= 0

          self.standard_flags_client_status_options = { group: group&.to_sym, max_age: max_age }.freeze
        end
      end

      # GET /client/status
      def client_status
        options = standard_flags_client_status_options
        result = ClientStatus.for(standard_flags_client, group: options[:group])
        response.cache_control.merge!(max_age: options[:max_age], public: false)
        vary = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        vary += StandardFlags.config.client_headers.values.compact.map(&:to_s)
        response.headers["Vary"] = vary.uniq(&:downcase).join(", ") unless vary.empty?
        render json: result.to_h
      end
    end
  end
end
