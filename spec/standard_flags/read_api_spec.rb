require "spec_helper"

RSpec.describe "read API" do
  before do
    define_flags do
      env_resolver -> { "production" }
      unit :account, from: ->(ctx) { ctx.account }
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, default: { production: true }
      kill_switch :ai_assistant, owner: "assistant"
      mode :strict_gates, owner: "platform", preset: :sensor
      experiment :home_hero, owner: "growth", variants: %w[control savings]
    end
  end

  it "answers on? and off?" do
    expect([ StandardFlags.on?(:new_checkout), StandardFlags.off?(:new_checkout) ]).to eq([ true, false ])
  end

  it "accepts string keys" do
    expect(StandardFlags.on?("new_checkout")).to be(true)
  end

  it "returns a Mode with predicates" do
    set_env("STANDARD_FLAGS_STRICT_GATES" => "sensor")
    mode = StandardFlags.mode(:strict_gates)
    expect([ mode.off?, mode.sensor?, mode.on? ]).to eq([ false, true, false ])
  end

  it "returns the variant" do
    expect(StandardFlags.variant(:home_hero)).to eq("control")
    expect(StandardFlags.variant(:new_checkout)).to eq("on")
  end

  it "makes peek the same as evaluate" do
    expect(StandardFlags.peek(:home_hero)).to eq(StandardFlags.evaluate(:home_hero))
  end

  it "returns frozen evaluations" do
    expect(StandardFlags.evaluate(:new_checkout)).to be_frozen.and(have_attributes(rule_id: nil, error?: false, pinned?: false))
  end

  it "re-reads ENV between reads outside a unit of work" do
    expect(StandardFlags.on?(:ai_assistant)).to be(true)
    set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off")
    expect(StandardFlags.on?(:ai_assistant)).to be(false)
  end

  describe ".snapshot" do
    it "freezes every flag's evaluation for one context" do
      snapshot = StandardFlags.snapshot(for: { account: "acct_1" })
      set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off")

      expect(snapshot).to be_frozen
      expect(snapshot.on?(:ai_assistant)).to be(true)
      expect(StandardFlags.on?(:ai_assistant)).to be(false)
      expect(snapshot.to_h.keys).to match_array(%i[new_checkout ai_assistant strict_gates home_hero])
      expect(snapshot[:home_hero].variant).to eq("control")
    end

    it "offers the full reader API" do
      snapshot = StandardFlags.snapshot
      expect([ snapshot.off?(:new_checkout), snapshot.mode(:strict_gates).off?, snapshot.variant(:home_hero) ])
        .to eq([ false, true, "control" ])
      expect(snapshot.each.map(&:key)).to include(:ai_assistant)
    end

    it "treats unknown keys like a live read" do
      expect { StandardFlags.snapshot.on?(:nope) }.to raise_error(StandardFlags::UnknownFlag)
    end
  end

  describe StandardFlags::Context do
    let(:account) { Struct.new(:id, :organization).new(7, :org) }

    it "wraps nil, hashes, single targets and contexts" do
      context = described_class.new(env: "staging")
      expect(described_class.wrap(nil)).to equal(described_class.empty)
      expect(described_class.wrap(context)).to equal(context)
      expect(described_class.wrap({ account: account }).account).to eq(account)
      expect(described_class.wrap(account).organization).to eq(:org)
    end

    it "lets a unit's from: lambda read actors" do
      context = described_class.wrap({ account: account })
      expect(StandardFlags.registry.units[:account].resolver.call(context)).to eq(account)
    end

    it "keys the memo by actor identity, env and target" do
      a = described_class.new(actors: { account: account }, env: "staging")
      b = described_class.new(actors: { account: account.dup }, env: "staging")
      c = described_class.new(actors: { account: account }, env: "production")
      expect(a.cache_key).to eq(b.cache_key)
      expect(a.cache_key).not_to eq(c.cache_key)
    end

    it "keys the memo by client attributes" do
      android = described_class.new(client: { platform: "android", version: "1.4.0" })
      same = described_class.new(client: { "version" => "1.4.0", "platform" => "android" })
      older = described_class.new(client: { platform: "android", version: "1.3.0" })
      ios = described_class.new(client: { platform: "ios", version: "1.4.0" })

      expect(android.cache_key).to eq(same.cache_key)
      expect([ older, ios, described_class.new ].map(&:cache_key)).not_to include(android.cache_key)
    end

    it "carries client attributes" do
      context = described_class.new(client: { "platform" => "android", version: "1.4.0" })
      expect(context.client).to eq(platform: "android", version: "1.4.0")
    end

    it "raises NoMethodError for things it doesn't know" do
      expect { described_class.new.organization }.to raise_error(NoMethodError)
      expect(described_class.new.actor(:organization)).to be_nil
    end
  end
end
