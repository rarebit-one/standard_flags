require "spec_helper"

RSpec.describe StandardFlags::Payload do
  before do
    define_flags do
      kill_switch :ai_assistant, owner: "assistant", expose: { web: :assistant, mobile: :chat }
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, expose: { web: :newCheckout }
      mode :strict_gates, owner: "platform", preset: :sensor, expose: { web: :gates }
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { web: :homeHero }
      flag :internal_only, owner: "platform", remove_by: "2027-01-01", final: true
    end
  end

  it "includes exposed flags only, keyed by wire name" do
    expect(StandardFlags.payload(:web))
      .to eq("assistant" => true, "gates" => "off", "homeHero" => "control", "newCheckout" => false)
  end

  it "shapes each audience separately" do
    expect(StandardFlags.payload(:mobile)).to eq("chat" => true)
    expect(StandardFlags.payload(:device)).to eq({})
  end

  it "never leaks unexposed keys" do
    expect(StandardFlags.payload(:web).keys.join).not_to include("internal")
  end

  it "reflects pins" do
    set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off")
    expect(StandardFlags.payload(:mobile)).to eq("chat" => false)
  end

  describe ".payload_digest" do
    it "is stable for the same answers and changes with them" do
      first = StandardFlags.payload_digest(:web)
      expect(StandardFlags.payload_digest(:web)).to eq(first)
      expect(first).to match(/\A\h{64}\z/)

      set_env("STANDARD_FLAGS_NEW_CHECKOUT" => "on")
      expect(StandardFlags.payload_digest(:web)).not_to eq(first)
    end

    it "ignores key order" do
      expect(described_class.digest("b" => 1, "a" => 2)).to eq(described_class.digest("a" => 2, "b" => 1))
    end
  end
end
