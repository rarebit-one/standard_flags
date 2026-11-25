require "spec_helper"
require "json_schemer"

RSpec.describe StandardFlags::Tooling::Manifest do
  before do
    StandardFlags.config.audiences = { web: {}, mobile: {}, pre_auth: { public: true, unit: :install }, kiosk: {} }
    define_flags do
      unit :install, from: ->(ctx) { ctx.actor(:install) }
      kill_switch :ai_assistant, owner: "assistant", description: "internal note", expose: { mobile: %i[chat chatEnabled], web: :assistant }
      flag :new_checkout, owner: "payments", remove_by: "2027-03-01", final: true, expose: { mobile: :newCheckout },
                          min_client: { android: "0.4", ios: "1.2.0-beta.1+77" }
      mode :billing_cutover, owner: "billing", preset: :cutover, remove_by: "2027-01-01", final: :all, expose: { web: :billing }
      mode :strict_gates, owner: "platform", preset: :sensor, permanent: true
      experiment :home_hero, owner: "growth", variants: %w[control savings], expose: { pre_auth: :homeHero }
      compat :legacy_auth, owner: "platform", remove_by: "2027-06-01"
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false, chatMode: "basic" } },
                          until: "2027-03-01", until_clients: { android: "0.6.0" }
      tombstone :old_banner, removed: "2025-01-01"
    end
  end

  let(:manifest) { described_class.new.to_h }
  let(:flags) { manifest["flags"].to_h { |entry| [ entry["key"], entry ] } }

  it "writes version 2 with every audience and whether it is public" do
    expect(manifest.keys).to eq(%w[version audiences flags tombstones])
    expect(manifest["version"]).to eq(2)
    expect(manifest["audiences"]).to eq(
      "kiosk" => { "public" => false }, "mobile" => { "public" => false },
      "pre_auth" => { "public" => true }, "web" => { "public" => false }
    )
  end

  it "lists every wire per audience, min_client and the lifecycle" do
    expect(flags["ai_assistant"]).to eq(
      "key" => "ai_assistant", "kind" => "kill_switch", "type" => "boolean", "values" => [ true, false ], "default" => true,
      "audiences" => { "mobile" => %w[chat chatEnabled], "web" => %w[assistant] }, "min_client" => {}
    )
    expect(flags["new_checkout"]).to include(
      "min_client" => { "android" => "0.4.0", "ios" => "1.2.0-beta.1" }, "permanent" => false,
      "remove_by" => "2027-03-01", "final" => true
    )
    expect(flags["billing_cutover"]).to include("type" => "string", "values" => %w[off allowlist all], "permanent" => false,
                                                "remove_by" => "2027-01-01", "final" => "all")
  end

  it "writes lifecycle keys only where they apply, and never owner or description" do
    expect(flags["strict_gates"]).to include("permanent" => true).and(satisfy { |entry| !entry.key?("remove_by") && !entry.key?("final") })
    expect(flags["home_hero"].keys).to eq(%w[key kind type values default audiences min_client])
    expect(flags["legacy_auth"]).to include("remove_by" => "2027-06-01").and(satisfy { |entry| !entry.key?("permanent") })
    expect(described_class.new.render).not_to include("owner", "description", "internal note", "payments")
  end

  it "lists deprecated wires on tombstones" do
    expect(manifest["tombstones"]).to eq([
      { "key" => "chat_v1", "removed" => "2026-12-01",
        "serve" => { "mobile" => { "chatMode" => "basic", "chat_v1" => false } },
        "until" => "2027-03-01", "until_clients" => { "android" => "0.6.0" } },
      { "key" => "old_banner", "removed" => "2025-01-01" }
    ])
  end

  it "derives audiences from flags and tombstones when config.audiences isn't set" do
    StandardFlags.config.audiences = nil
    define_flags do
      kill_switch :ai_assistant, owner: "assistant", expose: { web: :assistant }
      tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01"
    end

    expect(described_class.new.to_h["audiences"]).to eq("mobile" => { "public" => false }, "web" => { "public" => false })
  end

  it "validates against conformance/schema/manifest.schema.json" do
    schema = JSONSchemer.schema(Pathname.new(ConformanceRegistry.path("schema/manifest.schema.json")))

    expect(schema.validate(manifest).map { |error| error["error"] }).to eq([])
    expect(schema.validate(described_class.new(registry: StandardFlags::Registry.empty).to_h).to_a).to eq([])
    expect(schema.valid?(manifest.merge("version" => 1))).to be(false)
    expect(schema.valid?(manifest.merge("flags" => [ flags["ai_assistant"].merge("owner" => "x") ]))).to be(false)
  end

  it "renders deterministic JSON and digests its bytes" do
    render = described_class.new.render
    expect(render).to eq(described_class.new.render).and(end_with("}\n"))
    expect(described_class.new.digest).to eq(Digest::SHA256.hexdigest(render)).and(match(/\A\h{64}\z/))
  end

  describe ".read" do
    it "reads its own output: every wire with its type and source" do
      document = described_class.read(described_class.new.render)

      expect(document.version).to eq(2)
      expect(document.each_wire.map { |wire| [ wire.to_s, wire.type, wire.source, wire.key ] }).to eq([
        [ "mobile.chat", "boolean", :flag, "ai_assistant" ],
        [ "mobile.chatEnabled", "boolean", :flag, "ai_assistant" ],
        [ "mobile.chatMode", "string", :static, "chat_v1" ],
        [ "mobile.chat_v1", "boolean", :static, "chat_v1" ],
        [ "mobile.newCheckout", "boolean", :flag, "new_checkout" ],
        [ "pre_auth.homeHero", "string", :flag, "home_hero" ],
        [ "web.assistant", "boolean", :flag, "ai_assistant" ],
        [ "web.billing", "string", :flag, "billing_cutover" ]
      ])
      static = document.wire("mobile", "chat_v1")
      expect([ static.until, static.served_on?(Date.new(2027, 3, 1)), static.served_on?(Date.new(2027, 3, 2)) ])
        .to eq([ Date.new(2027, 3, 1), true, false ])
      expect(document.wire("web", "assistant").served_on?(Date.new(2999, 1, 1))).to be(true)
    end

    it "reads a version 1 manifest: first wires under audiences, aliases under wires" do
      v1 = {
        "version" => 1,
        "flags" => [
          { "key" => "ai", "kind" => "kill_switch", "type" => "boolean", "values" => [ true, false ], "default" => true,
            "audiences" => { "mobile" => "chat", "web" => "ai" }, "wires" => { "mobile" => %w[chat chatEnabled], "web" => %w[ai] } },
          { "key" => "hero", "kind" => "experiment", "values" => %w[a b], "default" => "a", "audiences" => { "web" => "hero" } },
          { "key" => "legacy", "kind" => "flag", "values" => [ true, false ], "default" => false, "audiences" => {}, "permanent" => true }
        ],
        "tombstones" => [ { "key" => "gone", "removed" => "2025-01-01" } ]
      }

      document = described_class.read(JSON.generate(v1))
      expect(document.each_wire.map { |wire| [ wire.to_s, wire.type ] })
        .to eq([ %w[mobile.chat boolean], %w[mobile.chatEnabled boolean], %w[web.ai boolean], %w[web.hero string] ])
    end

    it "accepts a parsed Hash" do
      expect(described_class.read(manifest).wires.keys).to contain_exactly("mobile", "pre_auth", "web")
    end

    {
      "not JSON" => [ "{", /not valid JSON/ ],
      "not an object" => [ "[]", /not a JSON object/ ],
      "an unknown version" => [ '{"version":3}', /unknown manifest version 3/ ],
      "no version" => [ "{}", /unknown manifest version nil/ ],
      "flags not an array" => [ '{"version":2,"flags":{}}', /flags is not an array/ ],
      "a flag that isn't an object" => [ '{"version":2,"flags":[1]}', /not an object/ ],
      "a flag without a key" => [ '{"version":2,"flags":[{}]}', /no key/ ],
      "an unknown type" => [ '{"version":2,"flags":[{"key":"a","type":"number"}]}', /unknown type "number"/ ],
      "audiences not an object" => [ '{"version":2,"flags":[{"key":"a","type":"boolean","audiences":[]}]}', /audiences is not an object/ ],
      "a wire that isn't a string" => [ '{"version":2,"flags":[{"key":"a","type":"boolean","audiences":{"web":[1]}}]}', /not a string/ ],
      "serve not an object" => [ '{"version":2,"tombstones":[{"key":"t","serve":[]}]}', /serve is not an object/ ],
      "serve audience not an object" => [ '{"version":2,"tombstones":[{"key":"t","serve":{"web":1}}]}', /serve.web is not an object/ ],
      "a static number" => [ '{"version":2,"tombstones":[{"key":"t","until":"2027-01-01","serve":{"web":{"w":1}}}]}', /neither a boolean nor a string/ ],
      "a bad until" => [ '{"version":2,"tombstones":[{"key":"t","until":"soon","serve":{"web":{"w":true}}}]}', /"soon" is not a YYYY-MM-DD date/ ]
    }.each do |label, (json, message)|
      it "refuses #{label}" do
        expect { described_class.read(json) }.to raise_error(described_class::Unreadable, message)
      end
    end
  end
end
