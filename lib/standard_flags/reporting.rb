require "set"
require "active_support/notifications"

module StandardFlags
  # Error reporting and instrumentation, both best-effort: nothing here may
  # raise into a flag read.
  #
  # @api private
  module Reporting
    SOURCE = "standard_flags".freeze

    @mutex = Mutex.new
    @seen = Set.new

    class << self
      # Runs the block the first time `token` is seen in this process, so a
      # bad pin read on every request reports once rather than per request.
      def once(*token)
        first = @mutex.synchronize { @seen.add?(token) }
        yield if first
        !first.nil?
      end

      def reset!
        @mutex.synchronize { @seen.clear }
      end

      # Reports a handled warning through `config.error_reporter` when one is
      # set, else through Rails.error, which hosts wire to their error
      # tracker. A custom reporter that raises falls back to Rails.error.
      def report(exception, **context)
        exception.set_backtrace(caller) if exception.backtrace.nil?
        return if custom_report(exception, context)

        reporter&.report(exception, handled: true, severity: :warning, context: context, source: SOURCE)
      rescue StandardError => e
        warn "[standard_flags] error report failed: #{e.class}: #{e.message}"
      end

      # Emits `<event>.standard_flags`. A failing subscriber must not break
      # the read that triggered it.
      def instrument(event, payload)
        ActiveSupport::Notifications.instrument("#{event}.standard_flags", payload)
      rescue StandardError => e
        warn "[standard_flags] #{event} notification failed: #{e.class}: #{e.message}"
      end

      private

      # true when a custom reporter took the report.
      def custom_report(exception, context)
        custom = StandardFlags.config.error_reporter
        return false unless custom

        custom.call(exception, context)
        true
      rescue StandardError => e
        warn "[standard_flags] config.error_reporter failed (#{e.class}); reporting through Rails.error"
        false
      end

      def reporter
        if defined?(::Rails) && ::Rails.respond_to?(:error)
          ::Rails.error
        elsif ActiveSupport.respond_to?(:error_reporter)
          ActiveSupport.error_reporter
        end
      end
    end
  end
end
