require "spec_helper"

RSpec.describe StandardFlags::Registry do
  describe "unit keys" do
    it "defaults to id.to_s, else the value itself, with blank as missing" do
      define_flags { unit :account, from: ->(ctx) { ctx.account } }
      unit = StandardFlags.registry.units[:account]
      expect(unit.key_for(RuntimeHelpers::Account.new(42))).to eq("42")
      expect(unit.key_for("acct_7")).to eq("acct_7")
      expect(unit.key_for(:acct_8)).to eq("acct_8")
      expect([ nil, "", "  ", RuntimeHelpers::Account.new(nil) ].map { |v| unit.key_for(v) }).to eq([ nil ] * 4)
    end

    it "normalises through key:" do
      define_flags { unit :phone, from: ->(ctx) { ctx.phone }, key: ->(phone) { phone.delete("^0-9+") } }
      unit = StandardFlags.registry.units[:phone]
      expect(unit.key_for("+65 9123 4567")).to eq("+6591234567")
      expect(unit.key_from(StandardFlags::Context.new(actors: { phone: "(9) 1-2" }))).to eq("912")
      expect(unit.key_for("---")).to be_nil
    end

    it "rejects a key: that can't be called" do
      expect { define_flags { unit :phone, from: ->(ctx) { ctx.phone }, key: "e164" } }
        .to raise_error(StandardFlags::DefinitionError, "unit :phone key: must respond to call(actor)")
    end
  end

  describe "bucketing:" do
    def migrated(**attributes)
      define_flags do
        unit :account, from: ->(ctx) { ctx.account }
        flag :migrated, owner: "growth", remove_by: "2027-01-01", final: true, unit: :account, **attributes
      end
      StandardFlags.registry[:migrated]
    end

    it "keeps a migrated flag's version and salt" do
      expect(migrated(bucketing: { version: 1, salt: "old_key" }).bucketing)
        .to eq(StandardFlags::Definition::Bucketing.new(version: 1, salt: "old_key"))
      expect(migrated.bucketing).to be_nil
    end

    it "is accepted by modes and experiments, not kill switches" do
      expect do
        define_flags do
          unit :account, from: ->(ctx) { ctx.account }
          mode :gates, owner: "p", preset: :sensor, unit: :account, bucketing: { version: 2, salt: "s" }
          experiment :hero, owner: "g", variants: %w[a b], unit: :account, bucketing: { "version" => 1, "salt" => "h" }
        end
      end.not_to raise_error
      expect { define_flags { kill_switch :ai, owner: "a", bucketing: { version: 2, salt: "s" } } }
        .to raise_error(StandardFlags::DefinitionError, /unknown attribute\(s\): :bucketing/)
    end

    {
      "not a Hash" => [ "v1", "must be a Hash with version: and salt:" ],
      "an unknown version" => [ { version: 3, salt: "s" }, "version: must be one of [1, 2]" ],
      "a blank salt" => [ { version: 1, salt: " " }, "salt: must be a non-blank String" ],
      "an unknown key" => [ { version: 1, salt: "s", seed: 1 }, "has unknown key(s): :seed" ]
    }.each do |label, (value, message)|
      it "rejects #{label}" do
        expect { migrated(bucketing: value) }.to raise_error(StandardFlags::DefinitionError, /bucketing: #{Regexp.escape(message)}/)
      end
    end

    it "needs a unit" do
      expect { define_flags { flag :x, owner: "o", remove_by: "2027-01-01", final: true, bucketing: { version: 2, salt: "s" } } }
        .to raise_error(StandardFlags::DefinitionError, "flag :x bucketing: needs a unit: to bucket")
    end
  end

  describe "values from the wire", registry: RuntimeHelpers::REGISTRY do
    it "casts stored strings through the definition" do
      registry = StandardFlags.registry
      expect(%w[on off].map { |text| registry[:new_checkout].value_from_wire(text) }).to eq([ true, false ])
      expect(registry[:strict_gates].value_from_wire("sensor")).to eq(:sensor)
      expect(registry[:home_hero].value_from_wire("savings")).to eq("savings")
      [ [ :new_checkout, "true" ], [ :strict_gates, "enforce" ], [ :home_hero, nil ] ].each do |key, text|
        expect(registry[key].value_from_wire(text)).to equal(StandardFlags::Parser::INVALID)
      end
    end
  end
end
