require "active_support/notifications"

module StandardFlags
  # Registers the internal Logger / Sentry / Metrics subscribers, plus any
  # `config.add_notifier` callables, for every `*.standard_flags` event:
  #
  # * evaluate.standard_flags     — sampled by `config.evaluate_sample_rate`
  # * sensor.standard_flags       — a sensor-mode observation
  # * pin_rejected.standard_flags — an ENV pin that didn't parse
  # * forbidden.standard_flags    — a `forbidden_in` flag pinned on
  # * legacy_env.standard_flags   — a legacy env name in use
  # * runtime_refresh.standard_flags       — runtime rules reloaded
  # * runtime_stale.standard_flags         — a runtime refresh failed; the
  #                                          last good rules keep serving
  # * rule_invalid.standard_flags          — a stored rule its flag can't serve
  # * targeting_key_missing.standard_flags — a rule needs a unit key the
  #                                          context doesn't have
  # * client_invalid.standard_flags        — a client header that didn't
  #                                          parse (field and header name)
  #
  # @api private
  class Subscribers
    EVENT_PATTERN = /\.standard_flags\z/

    def initialize
      @handles = []
    end

    def setup!
      teardown!
      (internal_subscribers + StandardFlags.config.extra_notifiers).each do |subscriber|
        @handles << ActiveSupport::Notifications.subscribe(EVENT_PATTERN) do |name, _start, _finish, _id, payload|
          subscriber.call(name, payload)
        end
      end
    end

    def teardown!
      @handles.each { |handle| ActiveSupport::Notifications.unsubscribe(handle) }
      @handles.clear
    end

    private

    def internal_subscribers
      config = StandardFlags.config
      list = [ Notifiers::Logger.new(config.logger) ]
      list << Notifiers::Sentry.new if config.sentry_enabled
      list << Notifiers::Metrics.new(metric_prefix: config.metric_prefix) if config.metrics_enabled
      list
    end
  end
end
