require "spec_helper"

RSpec.describe StandardFlags::Definition do
  def build(kind, key = :new_checkout, **attributes)
    described_class.new(kind, key, attributes)
  end

  def release(**attributes)
    build(:flag, **{ owner: "payments", remove_by: "2027-01-01", final: true }.merge(attributes))
  end

  describe "kinds and their defaults" do
    it "defaults a flag to off and requires lifecycle attributes" do
      flag = release
      expect([ flag.kind_default, flag.fail_value, flag.remove_by, flag.final ]).to eq([ false, false, Date.new(2027, 1, 1), true ])
    end

    it "defaults a kill switch to on and fails open" do
      switch = build(:kill_switch, :ai_assistant, owner: "assistant")
      expect([ switch.kind_default, switch.fail_value ]).to eq([ true, true ])
    end

    it "resolves mode presets" do
      expect(build(:mode, preset: :sensor, owner: "x").values).to eq(%i[off sensor on])
      expect(build(:mode, preset: :cutover, owner: "x").values).to eq(%i[off allowlist all])
      expect(build(:mode, preset: :shadow, owner: "x").values).to eq(%i[off shadow enforce])
    end

    it "takes explicit mode values as symbols" do
      expect(build(:mode, values: %w[off read_only full], owner: "x").values).to eq(%i[off read_only full])
    end

    it "defaults an experiment to its first variant" do
      experiment = build(:experiment, :home_hero, owner: "growth", variants: %i[control savings])
      expect([ experiment.kind_default, experiment.variants ]).to eq([ "control", %w[control savings] ])
    end

    it "defaults a compat flag to on" do
      expect(build(:compat, :legacy_form_auth, owner: "identity").kind_default).to be(true)
    end
  end

  describe "#default_for" do
    it "reads per-environment defaults with symbol or string keys" do
      flag = release(default: { staging: true, "sandbox" => true })
      expect(%w[staging sandbox production].map { |env| flag.default_for(env) }).to eq([ true, true, false ])
    end

    it "accepts a scalar default" do
      expect(release(default: true).default_for("production")).to be(true)
    end
  end

  describe "#variant_for" do
    it "maps booleans to on/off and other values to strings" do
      expect(release.variant_for(true)).to eq("on")
      expect(build(:mode, preset: :sensor, owner: "x").variant_for(:sensor)).to eq("sensor")
      expect(release.variant_for(nil)).to be_nil
    end
  end

  describe "#expose" do
    it "keeps wire names separate from the key" do
      flag = build(:kill_switch, :ai_assistant, owner: "x", expose: { web: :assistant, mobile: "chat" })
      expect([ flag.wire_name(:web), flag.wire_name("mobile"), flag.wire_name(:device) ]).to eq([ "assistant", "chat", nil ])
    end

    it "uses the key for an audience list" do
      expect(build(:kill_switch, :ai_assistant, owner: "x", expose: %i[web mobile]).expose)
        .to eq(web: "ai_assistant", mobile: "ai_assistant")
    end

    it "exposes nothing by default" do
      expect(release.expose).to eq({})
    end
  end

  describe "validation" do
    it "rejects an unknown kind" do
      expect { build(:toggle) }.to raise_error(StandardFlags::DefinitionError, /unknown flag kind/)
    end

    it "rejects a malformed key" do
      expect { build(:kill_switch, "New-Checkout", owner: "x") }.to raise_error(StandardFlags::DefinitionError, /must match/)
    end

    it "requires an owner" do
      expect { build(:kill_switch, owner: " ") }.to raise_error(StandardFlags::DefinitionError, /missing owner/)
    end

    it "requires remove_by and final on a release flag" do
      expect { build(:flag, owner: "x", final: true) }.to raise_error(StandardFlags::DefinitionError, /remove_by/)
      expect { build(:flag, owner: "x", remove_by: "2027-01-01") }.to raise_error(StandardFlags::DefinitionError, /final/)
    end

    it "rejects a malformed remove_by" do
      expect { release(remove_by: "next spring") }.to raise_error(StandardFlags::DefinitionError, /YYYY-MM-DD/)
    end

    it "rejects unknown attributes per kind" do
      expect { build(:kill_switch, owner: "x", remove_by: "2027-01-01") }
        .to raise_error(StandardFlags::DefinitionError, /unknown attribute\(s\): :remove_by/)
      expect { release(sticky: true) }.to raise_error(StandardFlags::DefinitionError, /:sticky/)
    end

    it "rejects a mode default outside its values" do
      expect { build(:mode, preset: :sensor, owner: "x", default: :enforce) }
        .to raise_error(StandardFlags::DefinitionError, /default: :enforce is not one of/)
    end

    it "rejects a per-environment default outside the values" do
      expect { release(default: { staging: "yes" }) }.to raise_error(StandardFlags::DefinitionError, /default: "yes"/)
    end

    it "needs exactly one of preset: or values: on a mode" do
      expect { build(:mode, owner: "x") }.to raise_error(StandardFlags::DefinitionError, /preset: or values:/)
      expect { build(:mode, owner: "x", preset: :sensor, values: %i[a b]) }.to raise_error(StandardFlags::DefinitionError)
      expect { build(:mode, owner: "x", preset: :dial) }.to raise_error(StandardFlags::DefinitionError, /preset: must be/)
      expect { build(:mode, owner: "x", values: %i[on]) }.to raise_error(StandardFlags::DefinitionError, /two unique/)
    end

    it "needs two unique experiment variants" do
      expect { build(:experiment, owner: "x", variants: %w[control]) }.to raise_error(StandardFlags::DefinitionError, /variants/)
      expect { build(:experiment, owner: "x") }.to raise_error(StandardFlags::DefinitionError, /variants/)
    end

    it "rejects a fail value outside the values" do
      expect { build(:mode, preset: :sensor, owner: "x", fail: :maybe) }.to raise_error(StandardFlags::DefinitionError, /fail:/)
    end

    it "validates env names" do
      expect { build(:kill_switch, owner: "x", env: "ai-disabled") }.to raise_error(StandardFlags::DefinitionError, /not an environment/)
      expect { build(:kill_switch, owner: "x", env: "STANDARD_FLAGS_NEW_CHECKOUT") }
        .to raise_error(StandardFlags::DefinitionError, /canonical name/)
    end

    it "only inverts legacy names of on/off kinds" do
      expect { build(:kill_switch, owner: "x", inverted: true) }.to raise_error(StandardFlags::DefinitionError, /legacy env:/)
      expect { build(:mode, preset: :sensor, owner: "x", env: "ACME_MODE", inverted: true) }
        .to raise_error(StandardFlags::DefinitionError, /on\/off kinds/)
      expect { build(:kill_switch, owner: "x", env: "ACME_X", inverted: "yes") }
        .to raise_error(StandardFlags::DefinitionError, /true or false/)
    end

    it "rejects a default that is on where the flag is forbidden" do
      expect { release(default: { production: true }, forbidden_in: :production) }
        .to raise_error(StandardFlags::DefinitionError, /forbidden_in/)
    end

    it "rejects a malformed wire name" do
      expect { build(:kill_switch, owner: "x", expose: { web: "new-checkout" }) }
        .to raise_error(StandardFlags::DefinitionError, /wire name/)
    end
  end

  describe "#stale?" do
    it "is true past remove_by" do
      flag = release(remove_by: "2026-01-01")
      expect([ flag.stale?(Date.new(2025, 12, 31)), flag.stale?(Date.new(2026, 1, 2)) ]).to eq([ false, true ])
    end
  end

  it "is frozen" do
    expect(release).to be_frozen
  end
end
