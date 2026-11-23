require "spec_helper"

# The cases every evaluator must agree on live in the conformance fixtures.
# This file covers the Ruby-side effects: reporting, notifications, error
# isolation and strictness.
RSpec.describe "resolution" do
  before do
    define_flags do
      env_resolver -> { "production" }
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true
      kill_switch :ai_assistant, owner: "assistant", env: "ACME_LEGACY_DISABLED", inverted: true
      flag :demo_data, owner: "platform", remove_by: "2027-01-01", final: false, forbidden_in: :production
      mode :strict_gates, owner: "platform", preset: :sensor
    end
  end

  describe "test overrides" do
    it "beat ENV pins and guards" do
      set_env("STANDARD_FLAGS_NEW_CHECKOUT" => "off")
      with_flag(:new_checkout, true) do
        expect(StandardFlags.evaluate(:new_checkout)).to have_attributes(value: true, reason: "STATIC")
      end
      expect(StandardFlags.evaluate(:new_checkout)).to have_attributes(value: false, reason: "ENV_PIN")
    end

    it "are inert until activated" do
      with_flag(:new_checkout, true) do
        StandardFlags::Testing.deactivate!
        expect(StandardFlags.on?(:new_checkout)).to be(false)
      end
    end
  end

  describe "rejected pins" do
    it "are ignored and reported once per process per variable" do
      set_env("STANDARD_FLAGS_NEW_CHECKOUT" => "enabled")
      events = nil
      collector = collect_errors do
        events = capture_events { 3.times { StandardFlags.evaluate(:new_checkout) } }
      end

      rejected = collector.errors_of(StandardFlags::PinRejected)
      expect(rejected.size).to eq(1)
      expect(rejected.first.message).to include("STANDARD_FLAGS_NEW_CHECKOUT").and(satisfy { |m| !m.include?("enabled") })
      expect(collector.reports.first).to include(handled: true, severity: :warning, source: "standard_flags")
      expect(events.map(&:first)).to eq([ "pin_rejected.standard_flags" ])
      expect(events.first.last).to include(key: :new_checkout, env_var: "STANDARD_FLAGS_NEW_CHECKOUT")
    end
  end

  describe "legacy names" do
    it "emit legacy_env once, marking a shadowed legacy name" do
      set_env("STANDARD_FLAGS_AI_ASSISTANT" => "on", "ACME_LEGACY_DISABLED" => "true")
      events = capture_events { 2.times { StandardFlags.evaluate(:ai_assistant) } }

      expect(events).to eq([ [ "legacy_env.standard_flags",
                               { key: :ai_assistant, env_var: "ACME_LEGACY_DISABLED",
                                 canonical: "STANDARD_FLAGS_AI_ASSISTANT", shadowed: true } ] ])
    end

    it "read 'false' on an inverted *_DISABLED name as enabled" do
      set_env("ACME_LEGACY_DISABLED" => "false")
      expect(StandardFlags.on?(:ai_assistant)).to be(true)
    end
  end

  describe "forbidden_in" do
    it "forces off and reports a pin that tries to turn it on, once" do
      set_env("STANDARD_FLAGS_DEMO_DATA" => "on")
      events = nil
      collector = collect_errors { events = capture_events { 2.times { StandardFlags.evaluate(:demo_data) } } }

      expect(StandardFlags.evaluate(:demo_data)).to have_attributes(value: false, reason: "DISABLED")
      expect(collector.errors_of(StandardFlags::ForbiddenPin).size).to eq(1)
      expect(events).to eq([ [ "forbidden.standard_flags",
                               { key: :demo_data, env: "production", env_var: "STANDARD_FLAGS_DEMO_DATA" } ] ])
    end

    it "stays quiet when nothing tries to turn it on" do
      set_env("STANDARD_FLAGS_DEMO_DATA" => "off")
      events = capture_events { StandardFlags.evaluate(:demo_data) }
      expect(events).to be_empty
    end

    it "can't be relaxed by a context environment: the process environment still forbids" do
      set_env("STANDARD_FLAGS_DEMO_DATA" => "on")
      staging = StandardFlags::Context.new(env: "staging")
      expect(StandardFlags.evaluate(:demo_data, for: staging)).to have_attributes(value: false, reason: "DISABLED")
    end

    it "is applied by a context environment that is forbidden" do
      define_flags do
        env_resolver -> { "staging" }
        flag :demo_data, owner: "platform", remove_by: "2027-01-01", final: false, forbidden_in: :production
      end
      set_env("STANDARD_FLAGS_DEMO_DATA" => "on")
      expect(StandardFlags.on?(:demo_data)).to be(true)
      expect(StandardFlags.evaluate(:demo_data, for: StandardFlags::Context.new(env: "production")))
        .to have_attributes(value: false, reason: "DISABLED")
    end
  end

  describe "error isolation" do
    it "returns the fail value with reason ERROR and leaves other flags alone" do
      define_flags do
        env_resolver -> { raise "resolver down" }
        kill_switch :ai_assistant, owner: "x"
        mode :strict_gates, owner: "x", preset: :sensor, fail: :sensor
      end
      collector = collect_errors do
        expect(StandardFlags.evaluate(:ai_assistant)).to have_attributes(value: true, reason: "ERROR", error_code: "GENERAL")
        expect(StandardFlags.evaluate(:strict_gates)).to have_attributes(value: :sensor, reason: "ERROR")
      end
      expect(collector.reports.map { |r| r[:error].message }).to eq([ "resolver down", "resolver down" ])
    end

    it "isolates a failing env source to the flag being read" do
      source = Object.new
      def source.[](name) = name == "STANDARD_FLAGS_NEW_CHECKOUT" ? raise("boom") : nil
      set_env(source)

      expect(StandardFlags.evaluate(:new_checkout)).to have_attributes(value: false, reason: "ERROR")
      expect(StandardFlags.evaluate(:ai_assistant)).to have_attributes(value: true, reason: "DEFAULT")
    end
  end

  describe "unknown keys" do
    it "raise in strict mode, naming a tombstone" do
      define_flags { tombstone :manual_entry, removed: "2026-12-01" }
      expect { StandardFlags.on?(:nope) }.to raise_error(StandardFlags::UnknownFlag, /unknown flag :nope/)
      expect { StandardFlags.on?(:manual_entry) }.to raise_error(StandardFlags::UnknownFlag, /removed on 2026-12-01/)
    end

    it "fail safe and report once outside strict mode" do
      StandardFlags.config.strict = false
      collector = collect_errors do
        expect(StandardFlags.evaluate("nope")).to have_attributes(value: nil, reason: "ERROR", error_code: "FLAG_NOT_FOUND")
        expect(StandardFlags.on?(:nope)).to be(false)
        expect(StandardFlags.off?(:nope)).to be(true)
        expect(StandardFlags.mode(:nope)).to be_unknown
      end
      expect(collector.errors_of(StandardFlags::UnknownFlag).size).to eq(1)
    end
  end

  describe "kind mismatches" do
    it "raise in strict mode" do
      expect { StandardFlags.on?(:strict_gates) }.to raise_error(StandardFlags::TypeMismatch, /read it with mode/)
      expect { StandardFlags.mode(:new_checkout) }.to raise_error(StandardFlags::TypeMismatch, /read it with on\?/)
    end

    it "read as off outside strict mode" do
      StandardFlags.config.strict = false
      collector = collect_errors do
        expect(StandardFlags.on?(:strict_gates)).to be(false)
        expect(StandardFlags.mode(:new_checkout).on?).to be(false)
      end
      expect(collector.errors_of(StandardFlags::TypeMismatch).size).to eq(2)
    end
  end

  describe "sampled evaluate events" do
    it "emits none by default" do
      expect(capture_events { StandardFlags.evaluate(:new_checkout) }).to be_empty
    end

    it "emits every evaluation at rate 1" do
      StandardFlags.config.evaluate_sample_rate = 1
      events = capture_events { StandardFlags.evaluate(:new_checkout) }
      expect(events).to eq([ [ "evaluate.standard_flags",
                               { key: :new_checkout, value: false, variant: "off", reason: "DEFAULT",
                                 error_code: nil, rule_id: nil, source_env_var: nil } ] ])
    end
  end

  it "never lets a failing subscriber break a read" do
    StandardFlags.config.evaluate_sample_rate = 1
    handle = ActiveSupport::Notifications.subscribe("evaluate.standard_flags") { raise "subscriber bug" }
    expect { StandardFlags.evaluate(:new_checkout) }.to output(/notification failed/).to_stderr
  ensure
    ActiveSupport::Notifications.unsubscribe(handle)
  end
end
