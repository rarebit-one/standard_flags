module StandardFlags
  module Notifiers
    # Sends a handled warning to Sentry for rejected and forbidden pins, with a
    # stable fingerprint per flag and variable. Opt in with
    # `config.sentry_enabled = true` only when Rails.error isn't already wired
    # to Sentry; otherwise each warning arrives twice.
    class Sentry
      EVENTS = %w[pin_rejected.standard_flags forbidden.standard_flags].freeze

      def call(event_name, payload)
        return unless EVENTS.include?(event_name)
        return unless defined?(::Sentry) && ::Sentry.respond_to?(:capture_message)

        kind = event_name.delete_suffix(".standard_flags")
        message = "standard_flags #{kind}: :#{payload[:key]} via #{payload[:env_var]}"
        ::Sentry.capture_message(
          message,
          level: :warning,
          tags: { flag: payload[:key].to_s, flag_event: kind },
          fingerprint: [ "standard_flags", kind, payload[:key].to_s, payload[:env_var].to_s ],
          extra: { env_var: payload[:env_var], env: payload[:env] }.compact
        )
        message
      end
    end
  end
end
