require "spec_helper"

RSpec.describe StandardFlags::Delivery do
  def build(audience = :mobile, client: {}, account: nil, today: Date.new(2026, 12, 1))
    context = StandardFlags::Context.new(actors: { account: account }.compact, client: client)
    described_class.build(audience, context, today: today)
  end

  def keys(result)
    result.entries.map(&:key)
  end

  before do
    define_flags do
      unit :account, from: ->(ctx) { ctx.account }
      kill_switch :ai, owner: "assistant", env: %w[ACME_AI_DISABLED], inverted: true,
                       expose: { mobile: %i[chat_enabled insights_enabled], web: :ai }
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account,
                          expose: { mobile: :checkoutV2 }, min_client: { android: "0.4.0", ios: "0.4.0" }
      mode :strict_gates, owner: "platform", preset: :sensor, expose: { mobile: :gates }
      experiment :home_hero, owner: "growth", variants: %w[control savings], unit: :account, expose: { mobile: :homeHero }
      flag :internal_only, owner: "platform", remove_by: "2027-01-01", final: true, unit: :account
      tombstone :chat_v1, removed: "2026-11-01", serve: { mobile: { chat_v1: false, chatMode: "legacy" } },
                          until: "2027-03-01", until_clients: { android: "0.6.0" }
    end
  end

  it "evaluates every exposed wire, aliases included, plus static wires, ordered by wire name" do
    result = build(client: { platform: "android", version: "0.5.0" })
    expect(result.flags).to eq([
      { "key" => "chatMode", "value" => "legacy", "reason" => "STATIC", "variant" => "legacy" },
      { "key" => "chat_enabled", "value" => true, "reason" => "DEFAULT", "variant" => "on" },
      { "key" => "chat_v1", "value" => false, "reason" => "STATIC", "variant" => "off" },
      { "key" => "checkoutV2", "value" => false, "reason" => "DEFAULT", "variant" => "off" },
      { "key" => "gates", "value" => "off", "reason" => "DEFAULT", "variant" => "off" },
      { "key" => "homeHero", "value" => "control", "reason" => "DEFAULT", "variant" => "control" },
      { "key" => "insights_enabled", "value" => true, "reason" => "DEFAULT", "variant" => "on" }
    ])
  end

  it "serves every alias the same evaluation, KILL_SWITCH visible" do
    set_env("STANDARD_FLAGS_AI" => "off")
    result = build
    expect([ result["chat_enabled"], result["insights_enabled"] ].map { |entry| entry.to_h.except("key") })
      .to all(eq("value" => false, "reason" => "KILL_SWITCH", "variant" => "off"))
  end

  describe "min_client:" do
    {
      "an older android build" => [ { platform: "android", version: "0.3.9" }, false ],
      "a prerelease of the minimum" => [ { platform: "android", version: "0.4.0-beta.1" }, false ],
      "the minimum" => [ { platform: "android", version: "0.4.0" }, true ],
      "a newer ios build" => [ { platform: "ios", version: "1.0.0" }, true ],
      "an android build with no version" => [ { platform: "android" }, false ],
      "an unparseable version" => [ { platform: "android", version: "0.4.0.1" }, false ],
      "a platform it doesn't list" => [ { platform: "web" }, true ],
      "an unrecognised platform (\"unknown\")" => [ { platform: "unknown", version: "9.0.0" }, false ],
      "a client that sends nothing" => [ {}, false ]
    }.each do |label, (client, delivered)|
      it "#{delivered ? 'delivers to' : 'withholds from'} #{label}" do
        expect(keys(build(client: client)).include?("checkoutV2")).to be(delivered)
      end
    end
  end

  describe "deprecated static wires" do
    it "stops at until_clients for that platform, and keeps serving unknown versions" do
      expect(keys(build(client: { platform: "android", version: "0.6.0" }))).not_to include("chat_v1")
      expect(keys(build(client: { platform: "android", version: "0.5.9" }))).to include("chat_v1")
      expect(keys(build(client: { platform: "android" }))).to include("chat_v1")
      expect(keys(build(client: { platform: "ios", version: "9.0.0" }))).to include("chat_v1")
    end

    it "compares until: with today's date in UTC, whatever the host's time zone" do
      late_evening_east_coast = Time.new(2027, 3, 1, 23, 30, 0, "-05:00") # 2027-03-02 04:30 UTC
      allow(Time).to receive(:now).and_return(late_evening_east_coast)
      context = StandardFlags::Context.new(client: { platform: "ios", version: "1.0.0" })
      expect(described_class.build(:mobile, context).entries.map(&:key)).not_to include("chat_v1")
    end

    it "serves through until: and disappears the day after" do
      expect(keys(build(today: Date.new(2027, 3, 1)))).to include("chat_v1", "chatMode")
      expect(keys(build(today: Date.new(2027, 3, 2)))).not_to include("chat_v1", "chatMode")
    end
  end

  it "isolates a flag whose evaluation fails as an OFREP evaluationFailure" do
    allow(StandardFlags::Resolvers::CHAIN.last).to receive(:call).and_wrap_original do |original, request|
      raise "boom" if request.definition.key == :strict_gates

      original.call(request)
    end
    result = nil
    collect_errors { result = build }
    expect(result["gates"].to_h)
      .to eq("key" => "gates", "errorCode" => "GENERAL", "errorDetails" => described_class::ERROR_DETAILS)
    expect(result["chat_enabled"].to_h["value"]).to be(true)
  end

  it "sends an error code OFREP doesn't allow on a flag as GENERAL" do
    expect(described_class::Entry.failed("x", StandardFlags::ErrorCode::TYPE_MISMATCH).error_code).to eq("GENERAL")
    expect(described_class::Entry.failed("x", StandardFlags::ErrorCode::PARSE_ERROR).error_code).to eq("PARSE_ERROR")
  end

  describe "what never leaves the server" do
    it "carries no flag keys, rule IDs, env var names, unit keys or server-only flags" do
      set_env("ACME_AI_DISABLED" => "true")
      with_members(:new_checkout, %w[acct-secret-42])
      with_rule(:home_hero, variants: { "control" => 0, "savings" => 10_000 })
      payload = JSON.generate(build(client: { platform: "android", version: "1.0.0" }, account: "acct-secret-42").to_h)

      expect(payload).not_to match(/new_checkout|strict_gates|home_hero|internal_only|\bai\b/)
      expect(payload).not_to match(/ACME_AI_DISABLED|STANDARD_FLAGS_|source_env_var|rule_id|allow|variants|acct-secret/)
      expect(JSON.parse(payload)["flags"].flat_map(&:keys).uniq.sort).to eq(%w[key reason value variant])
    end
  end

  describe "the ETag" do
    it "is the SHA-256 of the canonical JSON of the audience and entries" do
      result = build
      document = %({"audience":"mobile","flags":#{JSON.generate(result.entries.map { |entry| entry.to_h.sort.to_h })}})
      expect(result.etag).to eq(Digest::SHA256.hexdigest(document))
      expect(result.to_h["metadata"]).to eq("version" => result.etag)
    end

    it "is equal for equal answers and differs when the answers, client or audience differ" do
      expect(build(account: "a").etag).to eq(build(account: "b").etag)
      with_members(:new_checkout, %w[a])
      android = { platform: "android", version: "1.0.0" }
      expect(build(client: android, account: "a").etag).not_to eq(build(client: android, account: "b").etag)
      expect(build(client: android).etag).not_to eq(build(client: { platform: "android", version: "0.1.0" }).etag)
      expect(build(:mobile).etag).not_to eq(build(:web).etag)
    end

    it "ignores the config revision" do
      first = build.etag
      with_rule(:internal_only, percentage: 10_000)
      expect(build.etag).to eq(first)
    end

    it "matches If-None-Match quoted or bare, weak or strong, never *" do
      result = build
      matching = [ result.etag_header, result.etag, "W/#{result.etag_header}", "\"x\", #{result.etag_header}" ]
      expect(matching.map { |header| result.fresh?(header) }).to all(be(true))
      expect([ nil, "*", "\"x\"" ].map { |header| result.fresh?(header) }).to all(be(false))
    end
  end

  describe "audiences" do
    it "is empty for an audience nothing exposes to" do
      expect(build(:device).flags).to eq([])
    end

    it "refuses an undeclared audience when strict, and is empty otherwise" do
      StandardFlags.config.audiences = %i[mobile web]
      define_flags { kill_switch :ai, owner: "assistant", expose: { mobile: :chat } }
      expect { build(:device) }.to raise_error(ArgumentError, /not in config.audiences/)
      StandardFlags.config.strict = false
      expect(build(:device).flags).to eq([])
    end
  end

  describe ".build_anonymous" do
    before do
      StandardFlags.config.audiences = { mobile: {}, web: {}, pre_auth: { public: true, unit: :install } }
      StandardFlags.config.segment_resolver = ->(_name, _context) { raise "segments are never asked pre-auth" }
      define_flags do
        unit :account, from: ->(ctx) { ctx.account }
        unit :install, from: ->(ctx) { ctx.install }
        flag :login_banner, owner: "growth", remove_by: "2027-01-01", final: true, unit: :install,
                            expose: { pre_auth: :loginBanner }
        flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account, expose: { mobile: :checkoutV2 }
      end
    end

    it "serves a public audience, skipping segments" do
      with_rule(:login_banner, segments: { staff: true }, fallthrough: false)
      result = described_class.build_anonymous(:pre_auth, client: { platform: "ios" }, targeting_key: "install-1")
      expect(result.flags).to eq([ { "key" => "loginBanner", "value" => false, "reason" => "TARGETING_MATCH", "variant" => "off" } ])
    end

    it "refuses an audience that isn't public" do
      expect { described_class.build_anonymous(:mobile, client: {}) }.to raise_error(ArgumentError, /not a public audience/)
    end
  end

  describe "public-audience targeting" do
    before do
      StandardFlags.config.audiences = { mobile: {}, web: {}, pre_auth: { public: true, unit: :install } }
      define_flags do
        unit :install, from: ->(ctx) { ctx.install }
        flag :signup_v2, owner: "growth", remove_by: "2027-01-01", final: true, unit: :install, expose: { pre_auth: :signupV2 }
        flag :quiet, owner: "growth", remove_by: "2027-01-01", final: true, unit: :install, expose: { pre_auth: :quiet }
      end
    end

    it "warns once, when rules load, about a public flag with members or cohorts" do
      with_rule(:quiet, percentage: 5_000)
      with_members(:signup_v2, %w[install-1])
      events = capture_events(/public_targeting/) do
        2.times { described_class.build_anonymous(:pre_auth, client: {}, targeting_key: "install-1") }
      end
      expect(events.map(&:last)).to eq([ { key: :signup_v2, audience: :pre_auth } ])
      expect(StandardFlags::Notifiers::Logger.new(Logger.new(nil)).call("public_targeting.standard_flags", events.first.last))
        .to include(":signup_v2 is exposed to public audience :pre_auth", "unguessable install keys")
    end

    it "lists it in the runtime status the diagnostics read" do
      with_members(:signup_v2, %w[install-1])
      expect(StandardFlags::Runtime.status[:warnings]).to include(a_string_including(":signup_v2 is exposed to public audience"))
    end
  end

  describe "StandardFlags.payload" do
    it "keeps the flat format by default, aliases included and no static wires or min_client filter" do
      expect(StandardFlags.payload(:mobile)).to eq(
        "chat_enabled" => true, "checkoutV2" => false, "gates" => "off", "homeHero" => "control", "insights_enabled" => true
      )
    end

    it "returns the OFREP body with format: :ofrep and a client" do
      body = StandardFlags.payload(:mobile, client: { platform: "ios", version: "1.0.0" }, format: :ofrep)
      expect(body.keys).to eq(%w[flags metadata])
      expect(body["flags"].map { |entry| entry["key"] }).to include("checkoutV2", "chat_v1")
    end

    it "keeps payload_digest on the flat format" do
      expect(StandardFlags.payload_digest(:mobile)).to eq(StandardFlags::Payload.digest(StandardFlags.payload(:mobile)))
    end

    it "refuses an unknown format" do
      expect { StandardFlags.payload(:mobile, format: :json) }.to raise_error(ArgumentError, /format:/)
    end
  end
end
