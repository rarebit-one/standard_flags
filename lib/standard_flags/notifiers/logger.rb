require "logger"

module StandardFlags
  module Notifiers
    # Writes one log line per event: warnings for rejected, forbidden and
    # legacy pins, info for sensor observations, debug for sampled
    # evaluations. Lines carry variable names, never their values.
    class Logger
      PREFIX = "[standard_flags]".freeze

      def initialize(logger = nil)
        @logger = logger
      end

      def call(event_name, payload)
        level, message = build(event_name.delete_suffix(".standard_flags"), payload)
        return unless level

        logger.public_send(level, "#{PREFIX} #{message}")
        message
      end

      private

      def build(event, payload)
        case event
        when "pin_rejected"
          [ :warn, "ignored #{payload[:env_var]} for :#{payload[:key]}: expected one of #{Array(payload[:expected]).join('/')}" ]
        when "forbidden"
          [ :warn, "#{payload[:env_var]} pins :#{payload[:key]} on in #{payload[:env]}, where it is forbidden; forced off" ]
        when "legacy_env" then [ :warn, legacy_message(payload) ]
        when "sensor"
          [ :info, "sensor :#{payload[:key]} (#{payload[:mode]}) observed#{" #{payload[:error_class]}" if payload[:error_class]}" ]
        when "evaluate"
          [ :debug, "evaluated :#{payload[:key]} = #{payload[:value].inspect} (#{payload[:reason]})" ]
        when "runtime_stale" then [ :warn, stale_message(payload) ]
        when "runtime_refresh"
          [ :debug, "loaded runtime rules at revision #{payload[:revision]} (#{payload[:rules]} rules)" ]
        when "rule_invalid"
          [ :warn, "runtime rule for :#{payload[:key]} #{payload[:error]}; serving its fail value" ]
        when "targeting_key_missing"
          [ :debug, "runtime rule for :#{payload[:key]} needs a :#{payload[:unit]} key and the context has none" ]
        end
      end

      def stale_message(payload)
        serving = payload[:loaded] ? "revision #{payload[:revision]} (#{payload[:age]}s old)" : "code defaults (never loaded)"
        "runtime rules could not refresh (#{payload[:error_class]}); serving #{serving}"
      end

      def legacy_message(payload)
        message = "legacy #{payload[:env_var]} for :#{payload[:key]} is deprecated; rename it to #{payload[:canonical]}"
        payload[:shadowed] ? "#{message} (currently ignored: another pin wins)" : message
      end

      def logger
        @logger || (defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger) || (@fallback ||= ::Logger.new($stdout))
      end
    end
  end
end
