require "spec_helper"

RSpec.describe "exposure, min_client, audiences and deprecated wires" do
  def expect_refusal(message, &)
    expect { define_flags(&) }.to raise_error(StandardFlags::DefinitionError, message)
  end

  describe "expose: aliases" do
    it "keeps every wire name per audience, the first as wire_name" do
      define_flags { kill_switch :ai, owner: "x", expose: { mobile: %i[chat_enabled insights_enabled], web: :ai } }
      definition = StandardFlags.registry[:ai]
      expect([ definition.wire_name(:mobile), definition.wire_names(:mobile), definition.wire_names(:web) ])
        .to eq([ "chat_enabled", %w[chat_enabled insights_enabled], %w[ai] ])
      expect(definition.expose).to eq(mobile: "chat_enabled", web: "ai")
      expect(definition.wire_names(:device)).to eq([])
      expect(StandardFlags.registry.wires(:mobile).map(&:first)).to eq(%w[chat_enabled insights_enabled])
    end

    it "refuses an empty list, a bad name or a name listed twice" do
      expect_refusal(/lists no wire name for :mobile/) { kill_switch :ai, owner: "x", expose: { mobile: [] } }
      expect_refusal(/wire name "a-b" must match/) { kill_switch :ai, owner: "x", expose: { mobile: [ :ok, "a-b" ] } }
      expect_refusal(/lists a wire name twice for :mobile/) { kill_switch :ai, owner: "x", expose: { mobile: %i[a a] } }
    end

    it "refuses a wire name an alias of another flag already uses in that audience" do
      expect_refusal(/wire name "chat" for audience :mobile is used by both :ai and :chat_v2/) do
        kill_switch :ai, owner: "x", expose: { mobile: %i[assistant chat] }
        flag :chat_v2, owner: "x", remove_by: "2027-01-01", final: true, expose: { mobile: :chat }
      end
    end
  end

  describe "min_client:" do
    it "parses a version per platform" do
      define_flags { flag :f, owner: "x", remove_by: "2027-01-01", final: true, expose: [ :mobile ], min_client: { Android: "0.4.0" } }
      expect(StandardFlags.registry[:f].min_client).to eq("android" => StandardFlags::Version.parse("0.4.0"))
    end

    it "refuses bad declarations" do
      expect_refusal(/only applies to a flag with expose:/) { flag :f, owner: "x", remove_by: "2027-01-01", final: true, min_client: { ios: "1.0.0" } }
      expect_refusal(/must be a Hash/) { flag :f, owner: "x", remove_by: "2027-01-01", final: true, expose: [ :mobile ], min_client: "1.0.0" }
      expect_refusal(/must name at least one platform/) { flag :f, owner: "x", remove_by: "2027-01-01", final: true, expose: [ :mobile ], min_client: {} }
      expect_refusal(/platform :tv is not one of config.client_platforms/) do
        flag :f, owner: "x", remove_by: "2027-01-01", final: true, expose: [ :mobile ], min_client: { tv: "1.0.0" }
      end
      expect_refusal(/min_client: can't be used on a kill switch; a kill switch must reach every client/) do
        kill_switch :ai, owner: "x", expose: [ :mobile ], min_client: { android: "2.0.0" }
      end
      expect_refusal(/1 for ios is not a version/) { flag :f, owner: "x", remove_by: "2027-01-01", final: true, expose: [ :mobile ], min_client: { ios: 1 } }
    end
  end

  describe "config.audiences" do
    it "takes an Array or a Hash and refuses bad options" do
      StandardFlags.config.audiences = %i[web mobile]
      expect(StandardFlags.config.audiences.values.map(&:public?)).to eq([ false, false ])
      expect { StandardFlags.config.audiences = "web" }.to raise_error(ArgumentError, /Array of names or a Hash/)
      expect { StandardFlags.config.audiences = { web: { cache: true } } }.to raise_error(ArgumentError, /unknown option\(s\): :cache/)
      expect { StandardFlags.config.audiences = { web: { public: "yes" } } }.to raise_error(ArgumentError, /public: must be true or false/)
    end

    it "refuses a unit on a private audience and options that aren't a Hash" do
      expect { StandardFlags.config.audiences = { web: { unit: :install } } }.to raise_error(ArgumentError, /unit: only applies to a public/)
      expect { StandardFlags.config.audiences = { web: :public } }.to raise_error(ArgumentError, /options must be a Hash/)
    end

    it "requires every expose: and serve: audience to be declared" do
      StandardFlags.config.audiences = %i[web]
      expect_refusal(/:ai uses audience :mobile, which config.audiences doesn't declare/) { kill_switch :ai, owner: "x", expose: [ :mobile ] }
      expect_refusal(/tombstone :old uses audience :mobile/) do
        tombstone :old, removed: "2026-01-01", serve: { mobile: { old: true } }, until: "2027-01-01"
      end
    end

    it "keeps public audiences to their declared unit" do
      StandardFlags.config.audiences = { pre_auth: { public: true, unit: :install } }
      expect_refusal(/audience :pre_auth uses undeclared unit :install/) { flag :f, owner: "x", remove_by: "2027-01-01", final: true }
      expect_refusal(/exposed to public audience :pre_auth but uses unit :account; a public audience can only target unit :install/) do
        unit :install, from: ->(ctx) { ctx.install }
        unit :account, from: ->(ctx) { ctx.account }
        flag :f, owner: "x", remove_by: "2027-01-01", final: true, unit: :account, expose: [ :pre_auth ]
      end
      StandardFlags.config.audiences = { pre_auth: { public: true } }
      expect_refusal(/can only target no unit/) do
        unit :account, from: ->(ctx) { ctx.account }
        flag :f, owner: "x", remove_by: "2027-01-01", final: true, unit: :account, expose: [ :pre_auth ]
      end
    end

    it "derives private audiences from expose: when unset" do
      define_flags { kill_switch :ai, owner: "x", expose: [ :mobile ] }
      expect(StandardFlags.registry.audience(:mobile)).to eq(StandardFlags::Audience.new(name: :mobile, public: false, unit: nil))
      expect(StandardFlags.registry.audience(:device)).to be_nil
    end
  end

  describe "tombstone serve:" do
    def tombstone_of(key = :chat_v1)
      StandardFlags.registry.tombstones.fetch(key)
    end

    it "keeps static wires with until: and until_clients:" do
      define_flags do
        tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false, mode: :legacy } },
                            until: "2027-03-01", until_clients: { android: "0.6.0" }
      end
      expect(tombstone_of).to have_attributes(
        serve: { mobile: { "chat_v1" => false, "mode" => "legacy" } }, serve_until: Date.new(2027, 3, 1),
        until_clients: { "android" => StandardFlags::Version.parse("0.6.0") }
      )
      expect(StandardFlags.registry.deprecated_wires(:mobile).map(&:first)).to eq(%w[chat_v1 mode])
      expect(StandardFlags.registry.audience(:mobile)).not_to be_nil
    end

    it "refuses serve: with until_clients: alone, which would serve unknown clients forever" do
      expect_refusal(/serve: needs until: \(the last day the wire is served; until_clients: can only stop it sooner\)/) do
        tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until_clients: { ios: "2.0.0" }
      end
    end

    it "lets until_clients: only stop the wire sooner than until:" do
      define_flags do
        tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } }, until: "2027-03-01",
                            until_clients: { ios: "2.0.0" }
      end
      old_ios = StandardFlags::Client.new(platform: "ios", version: "1.0.0")
      expect([ tombstone_of.serving?(Date.new(2027, 3, 1)), tombstone_of.serves_client?(old_ios) ]).to eq([ true, true ])
      expect([ tombstone_of.serving?(Date.new(2027, 3, 2)), tombstone_of.serve_expired?(Date.new(2027, 3, 2)) ]).to eq([ false, true ])
    end

    it "refuses a static string that isn't valid UTF-8" do
      expect_refusal(/serve: banner must be valid UTF-8/) do
        tombstone :a, removed: "2026-01-01", serve: { mobile: { banner: "caf\xE9".b } }, until: "2027-01-01"
      end
    end

    it "refuses bad declarations" do
      expect_refusal(/until: needs serve:/) { tombstone :a, removed: "2026-01-01", until: "2027-01-01" }
      expect_refusal(/until_clients: needs serve:/) { tombstone :a, removed: "2026-01-01", until_clients: { ios: "1.0.0" } }
      expect_refusal(/serve: needs until:/) { tombstone :a, removed: "2026-01-01", serve: { mobile: { a: true } } }
      expect_refusal(/serve: must be a Hash/) { tombstone :a, removed: "2026-01-01", serve: [ :mobile ], until: "2027-01-01" }
      expect_refusal(/serve: for :mobile must be a Hash/) { tombstone :a, removed: "2026-01-01", serve: { mobile: true }, until: "2027-01-01" }
      expect_refusal(/serve: wire name "a-b"/) { tombstone :a, removed: "2026-01-01", serve: { mobile: { "a-b": true } }, until: "2027-01-01" }
      expect_refusal(/must serve true, false or a String, not 1/) { tombstone :a, removed: "2026-01-01", serve: { mobile: { a: 1 } }, until: "2027-01-01" }
      expect_refusal(/until: "soon" is not a YYYY-MM-DD date/) { tombstone :a, removed: "2026-01-01", serve: { mobile: { a: true } }, until: "soon" }
      expect_refusal(/until: 2025-01-01 is before removed: 2026-01-01/) { tombstone :a, removed: "2026-01-01", serve: { mobile: { a: true } }, until: "2025-01-01" }
      expect_refusal(/until_clients: must be a Hash/) do
        tombstone :a, removed: "2026-01-01", serve: { mobile: { a: true } }, until: "2027-01-01", until_clients: "1.0"
      end
      expect_refusal(/until_clients: platform :tv/) do
        tombstone :a, removed: "2026-01-01", serve: { mobile: { a: true } }, until: "2027-01-01", until_clients: { tv: "1.0.0" }
      end
    end

    it "refuses a static wire that clashes with a live flag's wire" do
      expect_refusal(/wire name "chat" for audience :mobile is used by both :ai and tombstone :chat_v1/) do
        kill_switch :ai, owner: "x", expose: { mobile: :chat }
        tombstone :chat_v1, removed: "2026-01-01", serve: { mobile: { chat: false } }, until: "2027-01-01"
      end
    end
  end

  describe "tooling" do
    before do
      define_flags do
        kill_switch :ai, owner: "assistant", expose: { mobile: %i[chat_enabled insights_enabled], web: :ai }
        flag :new_checkout, owner: "payments", remove_by: "2099-01-01", final: true, expose: { web: :newCheckout }
        tombstone :chat_v1, removed: "2026-01-01", serve: { mobile: { chat_v1: false } }, until: "2026-03-01"
        tombstone :old_banner, removed: "2025-01-01"
      end
    end

    it "lists every alias in the manifest under wires, keeping audiences as in version 1" do
      flags = StandardFlags::Tooling::Manifest.new.to_h["flags"].to_h { |entry| [ entry["key"], entry ] }
      expect(flags["ai"]).to include("audiences" => { "mobile" => "chat_enabled", "web" => "ai" },
                                     "wires" => { "mobile" => %w[chat_enabled insights_enabled], "web" => %w[ai] })
      expect(flags["new_checkout"]).not_to have_key("wires")
    end

    it "types every alias in the TypeScript features interface" do
      expect(StandardFlags::Tooling::TypeScript.new.render)
        .to include("export interface MobileFeatures {\n  readonly chat_enabled: boolean;\n  readonly insights_enabled: boolean;\n}")
    end

    it "reports a serve: block past its until: date as removable" do
      lines = StandardFlags::Tooling::Stale.new(today: Date.new(2026, 3, 2)).render.lines.map(&:chomp)
      expect(lines).to include("tombstone chat_v1 stopped serving mobile.chat_v1 after 2026-03-01; its serve: block can be removed")
      expect(StandardFlags::Tooling::Stale.new(today: Date.new(2026, 3, 1)).render).not_to include("tombstone")
    end
  end
end
