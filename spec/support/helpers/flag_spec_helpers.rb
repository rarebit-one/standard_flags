module FlagSpecHelpers
  SAMPLE_REGISTRY = proc do
    flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true
    kill_switch :ai_assistant, owner: "assistant"
    mode :strict_gates, owner: "platform", preset: :sensor
    experiment :home_hero, owner: "growth", variants: %w[control savings]
  end

  # Collects Rails.error reports for the duration of an example.
  class ErrorCollector
    attr_reader :reports

    def initialize
      @reports = []
    end

    def report(error, handled:, severity:, context:, source:)
      @reports << { error: error, handled: handled, severity: severity, context: context, source: source }
    end

    def errors_of(klass)
      reports.map { |r| r[:error] }.grep(klass)
    end
  end

  def define_flags(&)
    StandardFlags.define(&)
  end

  def set_env(vars)
    StandardFlags.config.env_source = vars
  end

  def collect_errors
    collector = ErrorCollector.new
    Rails.error.subscribe(collector)
    yield collector
    collector
  ensure
    Rails.error.unsubscribe(collector)
  end

  def capture_events(pattern = /\.standard_flags\z/)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(pattern) do |name, _start, _finish, _id, payload|
      events << [ name, payload ]
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
