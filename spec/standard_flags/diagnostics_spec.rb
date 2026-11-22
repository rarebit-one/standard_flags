require "spec_helper"
require "standard_health"

RSpec.describe StandardFlags::Diagnostics do
  before do
    define_flags do
      env_resolver -> { "production" }
      kill_switch :ai_assistant, owner: "assistant", env: "ACME_LEGACY_DISABLED", inverted: true, expose: { web: :assistant }
      flag :demo_data, owner: "platform", remove_by: "2027-01-01", final: false, forbidden_in: :production
      flag :old_banner, owner: "growth", remove_by: "2020-01-01", final: false
      mode :strict_gates, owner: "platform", preset: :sensor
    end
  end

  let(:secret) { "s3cr3t-value" }

  it "is ok with nothing to report" do
    report = described_class.report(today: Date.new(2019, 1, 1))
    expect(report).to include(status: :ok, environment: "production", forbidden_pins: [], rejected_pins: [], stale: [])
    expect(report[:flags].map { |f| f[:key] }).to eq(%i[ai_assistant demo_data old_banner strict_gates])
  end

  it "reports each flag's value and source" do
    set_env("ACME_LEGACY_DISABLED" => "true")
    row = described_class.report[:flags].find { |f| f[:key] == :ai_assistant }
    expect(row).to include(kind: :kill_switch, value: false, reason: "KILL_SWITCH", source_env_var: "ACME_LEGACY_DISABLED",
                           pinned: true, audiences: { "web" => "assistant" })
  end

  it "fails on a forbidden flag pinned on, and lists warnings" do
    set_env("STANDARD_FLAGS_DEMO_DATA" => "on", "STANDARD_FLAGS_STRICT_GATES" => secret,
            "ACME_LEGACY_DISABLED" => "false", "STANDARD_FLAGS_TYPO" => "on")
    report = described_class.report

    expect(report[:status]).to eq(:fail)
    expect(report[:forbidden_pins]).to eq([ { flag: :demo_data, env_var: "STANDARD_FLAGS_DEMO_DATA", environment: "production" } ])
    expect(report[:rejected_pins]).to eq([ { flag: :strict_gates, env_var: "STANDARD_FLAGS_STRICT_GATES" } ])
    expect(report[:unknown_env_vars]).to eq([ "STANDARD_FLAGS_TYPO" ])
    expect(described_class.warnings(report)).to contain_exactly(
      "STANDARD_FLAGS_STRICT_GATES for :strict_gates is not a valid value (ignored)",
      "ACME_LEGACY_DISABLED for :ai_assistant is deprecated; rename to STANDARD_FLAGS_AI_ASSISTANT",
      ":old_banner is past remove_by 2020-01-01",
      "STANDARD_FLAGS_TYPO does not match a declared flag"
    )
  end

  it "never includes raw environment values" do
    set_env("STANDARD_FLAGS_STRICT_GATES" => secret, "ACME_LEGACY_DISABLED" => secret)
    expect(described_class.report.inspect).not_to include(secret)
  end

  it "survives a failing env_resolver" do
    define_flags { env_resolver -> { raise "down" } }
    expect(described_class.report).to include(environment: nil, status: :ok)
  end

  describe StandardFlags::HealthCheck do
    it "is a standard_health check" do
      expect(described_class.new).to be_a(StandardHealth::Check).and(have_attributes(name: :standard_flags, critical: false))
    end

    it "passes with nothing to report" do
      define_flags { kill_switch :ai_assistant, owner: "assistant" }
      expect(described_class.new.run).to include(status: :ok).and(satisfy { |r| !r.key?(:warnings) })
    end

    it "fails on a forbidden pin" do
      set_env("STANDARD_FLAGS_DEMO_DATA" => "yes")
      expect(described_class.new.run).to include(
        status: :fail, error_class: "StandardFlags::ForbiddenPin",
        error: "forbidden flags pinned on: demo_data (STANDARD_FLAGS_DEMO_DATA)"
      )
    end

    it "carries warnings on an ok row by default" do
      expect(described_class.new.run).to include(status: :ok, warnings: [ ":old_banner is past remove_by 2020-01-01" ])
    end

    it "fails on warnings with warn_as: :fail" do
      expect(described_class.new(warn_as: :fail).run).to include(status: :fail, error_class: "StandardFlags::FlagWarning")
      expect { described_class.new(warn_as: :warn) }.to raise_error(ArgumentError)
    end

    it "reports a crash as a failure instead of raising" do
      allow(StandardFlags::Diagnostics).to receive(:report).and_raise("boom")
      expect(described_class.new.run).to include(status: :fail, error: "boom")
    end
  end
end
