module StandardFlags
  module Notifiers
    # Emits a Sentry::Metrics counter per event, `<prefix>.<event>`, tagged by
    # flag. No-ops when sentry-ruby (or its metrics API) isn't loaded.
    class Metrics
      def initialize(metric_prefix: "standard_flags")
        @metric_prefix = metric_prefix
      end

      def call(event_name, payload)
        return unless defined?(::Sentry::Metrics) && ::Sentry::Metrics.respond_to?(:count)

        event = event_name.delete_suffix(".standard_flags")
        ::Sentry::Metrics.count("#{@metric_prefix}.#{event}", value: 1, attributes: attributes(event, payload))
      end

      private

      def attributes(event, payload)
        attributes = { flag: payload[:key].to_s }
        case event
        when "evaluate" then attributes[:reason] = payload[:reason]
        when "sensor" then attributes[:mode] = payload[:mode].to_s
        end
        attributes
      end
    end
  end
end
