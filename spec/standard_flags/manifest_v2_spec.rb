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
    expect(manifest.keys).to eq(%w[version audiences flags tombstones clients])
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

  it "lists the client registry as declared in code, never pins or lookup answers" do
    lookup = ->(_app) { "9.9.9" }
    StandardFlags.config.audiences = nil
    define_flags do
      client :ios_app, platform: :ios, min_version: "2.0", since: "2026-12-01", recommended: "2.1.0", available: "2.1.0",
                       store_url: "https://example.com/ios", store_lookup: lookup, grace: 14
      client :android_app, platform: :android
      client :kiosk_web, platform: :web, group: :kiosk, min_version: "1.0.0", since: "2026-11-01"
    end
    set_env("STANDARD_FLAGS_CLIENT_IOS_APP_MIN_VERSION" => "1.2.3")

    expect(described_class.new.to_h["clients"]).to eq(
      "android_app" => { "platform" => "android", "group" => nil, "min_version" => nil, "since" => nil, "grace" => 7,
                         "recommended" => nil, "available" => nil, "store_url" => nil, "store_lookup" => false },
      "ios_app" => { "platform" => "ios", "group" => nil, "min_version" => "2.0.0", "since" => "2026-12-01", "grace" => 14,
                     "recommended" => "2.1.0", "available" => "2.1.0", "store_url" => "https://example.com/ios", "store_lookup" => true },
      "kiosk_web" => { "platform" => "web", "group" => "kiosk", "min_version" => "1.0.0", "since" => "2026-11-01", "grace" => 7,
                       "recommended" => nil, "available" => nil, "store_url" => nil, "store_lookup" => false }
    )
    expect(described_class.new.render).not_to include("9.9.9", "1.2.3", "IOS_APP_MIN_VERSION")
    expect(described_class.read(described_class.new.render).version).to eq(2)
  end

  it "writes an empty clients object without a client registry" do
    expect(manifest["clients"]).to eq({})
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

  it "spells out JSON.pretty_generate's layout, so the bytes don't hang on the json gem's defaults" do
    expect(described_class.new.render).to eq("#{JSON.pretty_generate(manifest)}\n")
    expect(described_class::FORMAT).to eq(indent: "  ", space: " ", object_nl: "\n", array_nl: "\n")
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
      "a version written as 2.0" => [ '{"version":2.0,"audiences":{},"flags":[],"tombstones":[]}', /unknown manifest version 2.0/ ],
      "a version 2 manifest without audiences" => [ '{"version":2,"flags":[],"tombstones":[]}', /needs audiences/ ],
      "audiences without public" => [ ManifestDocs.doc(audiences: { "web" => {} }), /audiences.web needs "public"/ ],
      "flags not an array" => [ ManifestDocs.doc(flags: {}), /flags is not an array/ ],
      "a flag that isn't an object" => [ ManifestDocs.doc(flags: [ 1 ]), /not an object/ ],
      "a flag without a key" => [ ManifestDocs.doc(flags: [ {} ]), /no key/ ],
      "an unknown type" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(type: "number") ]), /unknown type "number"/ ],
      "a missing type" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag.except("type") ]), /unknown type nil/ ],
      "values of the wrong type" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(values: %w[on off]) ]), /two unique boolean values/ ],
      "duplicate values" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(type: "string", "values" => %w[a a], "default" => "a") ]), /two unique string values/ ],
      "a default of the wrong type" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(default: { "*" => "off" }) ]), /default is not a boolean/ ],
      "a final of the wrong type" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(final: "on") ]), /final is not a boolean/ ],
      "audiences not an object" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(audiences: []) ]), /audiences is not an object/ ],
      "a bare-string wire list" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(audiences: { "web" => "a" }) ]), /audiences.web is not a non-empty array/ ],
      "a wire that isn't a string" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(audiences: { "web" => [ 1 ] }) ]), /not a string/ ],
      "a wire listed twice in one list" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(audiences: { "web" => %w[a a] }) ]), /web.a is listed twice/ ],
      "a wire on two flags" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag, ManifestDocs.flag(key: "b") ]), /web.a is listed twice \(flag b\)/ ],
      "a wire on a flag and a tombstone" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag ], tombstones: [ ManifestDocs.tombstone(serve: { "web" => { "a" => true } }) ]),
                                             /web.a is listed twice \(tombstone t\)/ ],
      "serve not an object" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone(serve: []) ]), /serve is not a non-empty object/ ],
      "an empty serve" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone(serve: {}) ]), /serve is not a non-empty object/ ],
      "serve without until" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone.except("until") ]), /serve needs until/ ],
      "serve without until_clients" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone.except("until_clients") ]), /serve needs until_clients/ ],
      "until_clients that isn't an object" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone(until_clients: []) ]), /serve needs until_clients/ ],
      "until without serve" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone.except("serve") ]), /until or until_clients without serve/ ],
      "serve audience not an object" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone(serve: { "web" => 1 }) ]), /serve.web is not an object/ ],
      "a static number" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone(serve: { "web" => { "w" => 1 } }) ]), /neither a boolean nor a string/ ],
      "a bad until" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone(until: "soon") ]), /"soon" is not a YYYY-MM-DD calendar date/ ],
      "an until that isn't a calendar date" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone(until: "2026-02-30") ]), /"2026-02-30" is not/ ],
      "a version 2 manifest without clients" => [ '{"version":2,"audiences":{},"flags":[],"tombstones":[]}', /needs clients/ ],
      "clients that aren't an object" => [ ManifestDocs.doc(clients: []), /clients is not an object/ ],
      "a client missing a field" => [ ManifestDocs.doc(clients: { "a" => ManifestDocs.client.except("grace") }), /clients.a needs exactly/ ],
      "a client with an extra field" => [ ManifestDocs.doc(clients: { "a" => ManifestDocs.client(pins: {}) }), /clients.a needs exactly/ ],
      "a client without a platform" => [ ManifestDocs.doc(clients: { "a" => ManifestDocs.client(platform: "") }), /platform is not a string/ ],
      "a client version that isn't a string" => [ ManifestDocs.doc(clients: { "a" => ManifestDocs.client(min_version: 4) }), /min_version is not a string or null/ ],
      "a client since that isn't a calendar date" => [ ManifestDocs.doc(clients: { "a" => ManifestDocs.client(since: "2026-02-30") }), /since "2026-02-30"/ ],
      "a client grace that isn't whole days" => [ ManifestDocs.doc(clients: { "a" => ManifestDocs.client(grace: 1.5) }), /grace is not a whole number/ ],
      "a client store_lookup that isn't a boolean" => [ ManifestDocs.doc(clients: { "a" => ManifestDocs.client(store_lookup: {}) }), /store_lookup is not true or false/ ],
      "a removed that isn't a calendar date" => [ ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone(removed: "2026-13-01") ]), /removed "2026-13-01"/ ],
      "a remove_by that isn't a date" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(remove_by: "soon") ]), /remove_by "soon" is not/ ],
      "a remove_by that isn't a calendar date" => [ ManifestDocs.doc(flags: [ ManifestDocs.flag(remove_by: "2027-02-30") ]), /remove_by "2027-02-30" is not/ ]
    }.each do |label, (json, message)|
      it "refuses #{label}" do
        expect { described_class.read(json) }.to raise_error(described_class::Unreadable, message)
      end
    end

    it "agrees with manifest.schema.json on what it refuses, except where a schema can't say" do
      schema = JSONSchemer.schema(Pathname.new(ConformanceRegistry.path("schema/manifest.schema.json")))
      schema_blind = [ "a version written as 2.0", "a wire on two flags", "a wire on a flag and a tombstone",
                       "an until that isn't a calendar date", "a removed that isn't a calendar date" ].freeze
      refused = {
        "a missing type" => ManifestDocs.doc(flags: [ ManifestDocs.flag.except("type") ]),
        "values of the wrong type" => ManifestDocs.doc(flags: [ ManifestDocs.flag(values: %w[on off]) ]),
        "a default of the wrong type" => ManifestDocs.doc(flags: [ ManifestDocs.flag(default: { "*" => "off" }) ]),
        "a bare-string wire list" => ManifestDocs.doc(flags: [ ManifestDocs.flag(audiences: { "web" => "a" }) ]),
        "a wire listed twice in one list" => ManifestDocs.doc(flags: [ ManifestDocs.flag(audiences: { "web" => %w[a a] }) ]),
        "serve without until" => ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone.except("until") ]),
        "serve without until_clients" => ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone.except("until_clients") ]),
        "a remove_by that isn't a date" => ManifestDocs.doc(flags: [ ManifestDocs.flag(remove_by: "soon") ]),
        "a remove_by that isn't a calendar date" => ManifestDocs.doc(flags: [ ManifestDocs.flag(remove_by: "2027-02-30") ]),
        "until without serve" => ManifestDocs.doc(tombstones: [ ManifestDocs.tombstone.except("serve") ]),
        "a client missing a field" => ManifestDocs.doc(clients: { "a" => ManifestDocs.client.except("grace") }),
        "a client store_lookup that isn't a boolean" => ManifestDocs.doc(clients: { "a" => ManifestDocs.client(store_lookup: {}) }),
        "a wire on a flag and a tombstone" => ManifestDocs.doc(flags: [ ManifestDocs.flag ], tombstones: [ ManifestDocs.tombstone(serve: { "web" => { "a" => true } }) ])
      }
      refused.each do |label, json|
        expect(schema.valid?(JSON.parse(json))).to be(schema_blind.include?(label)), label
      end
      expect(schema.valid?(JSON.parse(ManifestDocs.doc(flags: [ ManifestDocs.flag ], tombstones: [ ManifestDocs.tombstone ],
                                                       clients: { "a" => ManifestDocs.client })))).to be(true)
      expect(described_class.read(ManifestDocs.doc(flags: [ ManifestDocs.flag ], tombstones: [ ManifestDocs.tombstone ])).wires.keys).to eq(%w[web])
    end
  end
end
