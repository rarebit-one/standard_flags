require "spec_helper"
require "stringio"
require "sentry-ruby"

RSpec.describe "notifiers" do
  describe StandardFlags::Notifiers::Logger do
    let(:io) { StringIO.new }
    let(:notifier) { described_class.new(Logger.new(io)) }

    it "warns about rejected pins by name only" do
      notifier.call("pin_rejected.standard_flags", key: :new_checkout, env_var: "STANDARD_FLAGS_NEW_CHECKOUT", expected: [ true, false ])
      expect(io.string).to include("WARN", "[standard_flags] ignored STANDARD_FLAGS_NEW_CHECKOUT for :new_checkout: expected one of true/false")
    end

    it "warns about forbidden and legacy pins" do
      notifier.call("forbidden.standard_flags", key: :demo_data, env: "production", env_var: "STANDARD_FLAGS_DEMO_DATA")
      notifier.call("legacy_env.standard_flags", key: :ai_assistant, env_var: "ACME_LEGACY_DISABLED",
                    canonical: "STANDARD_FLAGS_AI_ASSISTANT", shadowed: true)
      expect(io.string).to include("where it is forbidden; forced off")
      expect(io.string).to include("rename it to STANDARD_FLAGS_AI_ASSISTANT (currently ignored: another pin wins)")
    end

    it "logs sensor observations at info and evaluations at debug" do
      notifier.call("sensor.standard_flags", key: :strict_gates, mode: :sensor, error_class: "RuntimeError")
      notifier.call("evaluate.standard_flags", key: :ai_assistant, value: true, reason: "DEFAULT")
      expect(io.string).to include("INFO", "sensor :strict_gates (sensor) observed RuntimeError")
      expect(io.string).to include("DEBUG", "evaluated :ai_assistant = true (DEFAULT)")
    end

    it "ignores other events" do
      expect(notifier.call("other.standard_flags", {})).to be_nil
    end

    it "falls back to Rails.logger" do
      expect(described_class.new.send(:logger)).to eq(Rails.logger)
    end
  end

  describe StandardFlags::Notifiers::Sentry do
    it "captures rejected and forbidden pins as handled warnings with a stable fingerprint" do
      allow(Sentry).to receive(:capture_message)
      described_class.new.call("pin_rejected.standard_flags", key: :new_checkout, env_var: "STANDARD_FLAGS_NEW_CHECKOUT")

      expect(Sentry).to have_received(:capture_message).with(
        "standard_flags pin_rejected: :new_checkout via STANDARD_FLAGS_NEW_CHECKOUT",
        level: :warning,
        tags: { flag: "new_checkout", flag_event: "pin_rejected" },
        fingerprint: [ "standard_flags", "pin_rejected", "new_checkout", "STANDARD_FLAGS_NEW_CHECKOUT" ],
        extra: { env_var: "STANDARD_FLAGS_NEW_CHECKOUT" }
      )
    end

    it "ignores other events" do
      allow(Sentry).to receive(:capture_message)
      described_class.new.call("sensor.standard_flags", key: :strict_gates)
      expect(Sentry).not_to have_received(:capture_message)
    end
  end

  describe StandardFlags::Notifiers::Metrics do
    it "counts each event with flag attributes" do
      allow(Sentry::Metrics).to receive(:count)
      notifier = described_class.new(metric_prefix: "flags")
      notifier.call("evaluate.standard_flags", key: :ai_assistant, reason: "DEFAULT")
      notifier.call("sensor.standard_flags", key: :strict_gates, mode: :on)

      expect(Sentry::Metrics).to have_received(:count)
        .with("flags.evaluate", value: 1, attributes: { flag: "ai_assistant", reason: "DEFAULT" })
      expect(Sentry::Metrics).to have_received(:count)
        .with("flags.sensor", value: 1, attributes: { flag: "strict_gates", mode: "on" })
    end
  end

  describe StandardFlags::Subscribers do
    it "wires internal subscribers and extra notifiers to *.standard_flags events" do
      received = []
      StandardFlags.configure do |config|
        config.logger = Logger.new(nil)
        config.metrics_enabled = false
        config.add_notifier(->(name, payload) { received << [ name, payload[:key] ] })
      end

      ActiveSupport::Notifications.instrument("sensor.standard_flags", key: :strict_gates)
      ActiveSupport::Notifications.instrument("sensor.other_gem", key: :ignored)
      expect(received).to eq([ [ "sensor.standard_flags", :strict_gates ] ])
    end

    it "does not stack subscribers when configure runs again" do
      received = []
      notifier = ->(name, _payload) { received << name }
      2.times { StandardFlags.configure { |config| config.add_notifier(notifier) } }

      ActiveSupport::Notifications.instrument("forbidden.standard_flags", key: :demo_data)
      expect(received.size).to eq(1)
    end

    it "builds the Sentry subscriber only when enabled" do
      StandardFlags.config.sentry_enabled = true
      kinds = StandardFlags.subscribers.send(:internal_subscribers).map(&:class)
      expect(kinds).to eq([ StandardFlags::Notifiers::Logger, StandardFlags::Notifiers::Sentry, StandardFlags::Notifiers::Metrics ])
    end

    it "rejects notifiers that can't be called" do
      expect { StandardFlags.config.add_notifier(Object.new) }.to raise_error(ArgumentError)
    end
  end
end
