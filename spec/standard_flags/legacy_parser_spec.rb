require "spec_helper"

# `legacy_parser: :exact`. Evaluation cases live in
# conformance/legacy_exact.json; these cover validation and the
# side of the scan the fixtures don't see.
RSpec.describe StandardFlags::Definition, "#legacy_parser" do
  def build(kind, key = :purge_inactive, **attributes)
    StandardFlags::Definition.new(kind, key, { owner: "platform" }.merge(attributes))
  end

  describe "declaration" do
    it "defaults to the strict parser with no legacy_true:" do
      flag = build(:flag, permanent: true, env: "ACME_PURGE")
      expect([ flag.legacy_parser, flag.legacy_true ]).to eq([ :strict, nil ])
    end

    it "defaults legacy_true: to on for on/off kinds read exactly" do
      expect(build(:flag, permanent: true, env: "ACME_PURGE", legacy_parser: :exact).legacy_true).to eq(%w[on])
      expect(build(:kill_switch, env: "ACME_PURGE_DISABLED", inverted: true, legacy_parser: "exact").legacy_true).to eq(%w[on])
    end

    it "has no legacy_true: for modes and experiments" do
      mode = build(:mode, preset: :sensor, env: "ACME_GATES", legacy_parser: :exact)
      experiment = build(:experiment, variants: %w[control savings], env: "ACME_HERO", legacy_parser: :exact)
      expect([ mode.legacy_true, experiment.legacy_true ]).to eq([ nil, nil ])
    end

    it "rejects an unknown parser" do
      expect { build(:flag, permanent: true, env: "ACME_PURGE", legacy_parser: :loose) }
        .to raise_error(StandardFlags::DefinitionError, /legacy_parser: must be one of \[:strict, :exact\]/)
      expect { build(:flag, permanent: true, env: "ACME_PURGE", legacy_parser: 1) }
        .to raise_error(StandardFlags::DefinitionError, /legacy_parser: must be one of/)
    end

    it "needs a legacy env: name, since the canonical pin is always strict" do
      expect { build(:flag, permanent: true, legacy_parser: :exact) }
        .to raise_error(StandardFlags::DefinitionError, /legacy_parser: needs a legacy env: name/)
    end

    it "takes legacy_true: only with the exact parser, on on/off kinds, non-blank" do
      expect { build(:flag, permanent: true, env: "ACME_PURGE", legacy_true: %w[on]) }
        .to raise_error(StandardFlags::DefinitionError, /legacy_true: needs legacy_parser: :exact/)
      expect { build(:mode, preset: :sensor, env: "ACME_GATES", legacy_parser: :exact, legacy_true: %w[on]) }
        .to raise_error(StandardFlags::DefinitionError, /legacy_true: only applies to on\/off kinds/)
      [ [], [ "" ], [ "on", " " ] ].each do |words|
        expect { build(:flag, permanent: true, env: "ACME_PURGE", legacy_parser: :exact, legacy_true: words) }
          .to raise_error(StandardFlags::DefinitionError, /legacy_true: must list at least one non-blank value/)
      end
    end

    it "keeps legacy_true: values exactly as written" do
      flag = build(:flag, permanent: true, env: "ACME_PURGE", legacy_parser: :exact, legacy_true: [ "On", :enabled ])
      expect(flag.legacy_true).to eq(%w[On enabled]).and(be_frozen)
    end
  end

  describe "scan" do
    before do
      define_flags do
        flag :purge_inactive, owner: "platform", permanent: true, env: "ACME_PURGE", legacy_parser: :exact
        mode :strict_gates, owner: "platform", preset: :sensor, env: "ACME_GATES", legacy_parser: :exact
      end
    end

    def scan(key, env)
      StandardFlags::EnvPin.scan(StandardFlags.registry[key], env)
    end

    it "never rejects an exact on/off legacy value: anything non-blank is a pin" do
      result = scan(:purge_inactive, "ACME_PURGE" => "definitely")
      expect([ result.pin.to_h, result.rejected ]).to eq([ { var: "ACME_PURGE", value: false, legacy: true }, [] ])
    end

    it "rejects an inexact legacy mode value and reports it like any unparseable pin" do
      set_env("ACME_GATES" => "SENSOR")
      expect(scan(:strict_gates, StandardFlags.config.env_source).rejected).to eq(%w[ACME_GATES])

      collector = collect_errors { expect(StandardFlags.mode(:strict_gates)).to be_off }
      expect(collector.errors_of(StandardFlags::PinRejected).map(&:message).join).to include("ACME_GATES")
      expect(StandardFlags::Diagnostics.report[:rejected_pins]).to eq([ { flag: :strict_gates, env_var: "ACME_GATES" } ])
    end

    it "pins an on/off flag off for a set-but-blank exact legacy value, as == \"on\" did" do
      [ "", " ", "\t", "\n" ].each do |raw|
        expect(scan(:purge_inactive, "ACME_PURGE" => raw).pin.to_h).to eq(var: "ACME_PURGE", value: false, legacy: true)
      end
      expect(scan(:purge_inactive, {}).pin).to be_nil
    end

    it "keeps a blank exact legacy value from falling through to a runtime rule that serves on" do
      StandardFlags::Testing.rule(:purge_inactive, fallthrough: true)
      [ "", " " ].each do |raw|
        set_env("ACME_PURGE" => raw)
        evaluation = StandardFlags.evaluate(:purge_inactive)
        expect([ evaluation.value, evaluation.reason ]).to eq([ false, StandardFlags::Reason::ENV_PIN ])
      end
      set_env({})
      expect(StandardFlags.evaluate(:purge_inactive).value).to be(true)
    end

    it "leaves a blank exact legacy mode value unset" do
      expect(scan(:strict_gates, "ACME_GATES" => " ").then { [ _1.pin, _1.rejected ] }).to eq([ nil, [] ])
    end

    it "leaves a blank inverted exact legacy value unset, since pinning it would turn the flag on" do
      define_flags do
        kill_switch :ai_assistant, owner: "assistant", env: "ACME_ASSISTANT_DISABLED", inverted: true,
                                   legacy_parser: :exact
      end
      expect(scan(:ai_assistant, "ACME_ASSISTANT_DISABLED" => "").pin).to be_nil
    end

    it "still treats a blank canonical pin as unset" do
      expect(scan(:purge_inactive, "STANDARD_FLAGS_PURGE_INACTIVE" => " ").then { [ _1.pin, _1.rejected ] })
        .to eq([ nil, [] ])
    end

    it "still parses the canonical pin strictly" do
      expect(scan(:purge_inactive, "STANDARD_FLAGS_PURGE_INACTIVE" => "definitely").rejected)
        .to eq(%w[STANDARD_FLAGS_PURGE_INACTIVE])
    end
  end
end
