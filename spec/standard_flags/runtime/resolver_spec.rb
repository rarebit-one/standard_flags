require "spec_helper"

RSpec.describe StandardFlags::Runtime::Resolver, registry: RuntimeHelpers::REGISTRY do
  def evaluate(key, id = 1, client: {})
    StandardFlags.evaluate(key, for: for_account(id, client: client))
  end

  describe "when runtime rules are off" do
    it "never reaches a store" do
      StandardFlags.config.runtime_store = StandardFlags::Runtime::MemoryStore.new
      StandardFlags.config.runtime_store.put_rule(:new_checkout, status: :running, fallthrough_value: true)

      expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "DEFAULT", rule_id: nil)
      expect(StandardFlags.config.runtime_store.reads).to be_empty
    end
  end

  describe "with a configured store" do
    let(:store) { StandardFlags::Runtime::MemoryStore.new }

    before do
      StandardFlags.config.runtime_rules = true
      StandardFlags.config.runtime_store = store
    end

    it "reads the configured store" do
      store.put_rule(:new_checkout, status: :running, fallthrough_value: true)
      expect(evaluate(:new_checkout)).to have_attributes(value: true, reason: "TARGETING_MATCH", rule_id: "fallthrough")
    end

    it "serves the code default for a flag without a rule" do
      store.put_rule(:global_banner, status: :running, fallthrough_value: true)
      expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "DEFAULT")
    end
  end

  describe "by status" do
    it "skips a draft rule" do
      with_rule(:new_checkout, status: :draft, fallthrough: true)
      expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "DEFAULT", rule_id: nil)
    end

    it "serves the code default for a paused rule, keeping its settings" do
      with_rule(:new_checkout, status: :paused, percentage: 10_000)
      expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "DEFAULT")
      expect(StandardFlags::Testing.runtime_store.rule(:new_checkout).percentage_bps).to eq(10_000)
    end

    it "serves the stop value to everyone when stopped" do
      with_rule(:new_checkout, status: :stopped, stop: true, percentage: 0)
      with_members(:new_checkout, account(1), value: false)
      expect(evaluate(:new_checkout)).to have_attributes(value: true, reason: "STATIC", rule_id: "stopped")
    end

    it "reads a stopped kill switch serving off as KILL_SWITCH" do
      with_rule(:ai_assistant, status: :stopped, stop: false)
      expect(evaluate(:ai_assistant)).to have_attributes(value: false, reason: "KILL_SWITCH", rule_id: "stopped")
    end
  end

  describe "memberships" do
    it "serves a direct member's value" do
      with_members(:strict_gates, account(1), value: :on)
      expect(evaluate(:strict_gates)).to have_attributes(value: :on, reason: "TARGETING_MATCH", rule_id: "allow")
      expect(evaluate(:strict_gates, 2)).to have_attributes(value: :off, reason: "DEFAULT")
    end

    it "lets a deny beat an allowing cohort" do
      with_cohort(:staff, unit: :account, members: [ account(1) ])
      with_rule(:new_checkout, cohorts: { staff: true })
      with_members(:new_checkout, account(1), value: false)
      expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "TARGETING_MATCH", rule_id: "deny")
    end

    it "ignores expired memberships" do
      with_members(:new_checkout, account(1), value: true, expires_at: Time.now - 1)
      with_members(:new_checkout, account(2), value: true, expires_at: Time.now + 3600)
      expect(evaluate(:new_checkout).rule_id).to be_nil
      expect(evaluate(:new_checkout, 2).rule_id).to eq("allow")
    end

    it "normalises unit keys through the unit's key:" do
      with_members(:phone_login, "+65 9123-4567", value: true)
      context = StandardFlags::Context.new(actors: { phone: "+6591234567" })
      expect(StandardFlags.evaluate(:phone_login, for: context)).to have_attributes(value: true, rule_id: "allow")
    end
  end

  describe "cohorts" do
    before do
      with_cohort(:staff, unit: :account, members: [ account(1), account(2) ])
      with_cohort(:testers, unit: :account, members: [ account(2), account(3) ])
    end

    it "serves the first matching cohort in declared order" do
      with_rule(:strict_gates, cohorts: [ { cohort: :testers, value: :sensor }, { cohort: :staff, value: :on } ])
      expect(evaluate(:strict_gates, 1)).to have_attributes(value: :on, rule_id: "cohort:staff")
      expect(evaluate(:strict_gates, 2)).to have_attributes(value: :sensor, rule_id: "cohort:testers")
    end

    it "lets a cohort serving the off value win over earlier ones" do
      with_rule(:new_checkout, cohorts: { staff: true, testers: false })
      expect(evaluate(:new_checkout, 2)).to have_attributes(value: false, reason: "TARGETING_MATCH", rule_id: "cohort:testers")
      expect(evaluate(:new_checkout, 1)).to have_attributes(value: true, rule_id: "cohort:staff")
    end

    it "skips archived cohorts and cohorts of another unit" do
      with_cohort(:old, unit: :account, members: [ account(4) ], archived: true)
      with_cohort(:phones, unit: :phone, members: [ "4" ])
      with_rule(:new_checkout, cohorts: { old: true, phones: true })
      expect(evaluate(:new_checkout, 4)).to have_attributes(value: false, reason: "DEFAULT")
    end
  end

  describe "segments" do
    it "skips segments without a segment_resolver" do
      with_rule(:new_checkout, segments: { beta: true })
      expect(evaluate(:new_checkout).reason).to eq("DEFAULT")
    end

    it "asks the segment_resolver, in order" do
      StandardFlags.config.segment_resolver = ->(name, context) { name == "beta" && context.account.id.odd? }
      with_rule(:new_checkout, segments: { alpha: false, beta: true })
      expect(evaluate(:new_checkout, 1)).to have_attributes(value: true, reason: "TARGETING_MATCH", rule_id: "segment:beta")
      expect(evaluate(:new_checkout, 2).reason).to eq("DEFAULT")
    end
  end

  describe "client conditions" do
    before { with_rule(:new_checkout, percentage: 10_000, fallthrough: false, platforms: %w[android ios], versions: { android: ">= 1.4.0, < 2" }) }

    it "rolls out when the platform and version match" do
      expect(evaluate(:new_checkout, client: { platform: "Android", version: "1.5.2" }))
        .to have_attributes(value: true, reason: "SPLIT", rule_id: "percentage")
      expect(evaluate(:new_checkout, client: { platform: "ios" }).rule_id).to eq("percentage")
    end

    it "goes to the fallthrough when they don't" do
      [ { platform: "android", version: "1.3.9" }, { platform: "android", version: "2.0.0" },
        { platform: "android" }, { platform: "android", version: "not-a-version" }, { platform: "web" }, {} ].each do |client|
        expect(evaluate(:new_checkout, client: client)).to have_attributes(value: false, rule_id: "fallthrough")
      end
    end

    it "fails only the flag on a malformed version range" do
      with_rule(:new_checkout, percentage: 10_000, versions: { android: "around 1.4" })
      expect(evaluate(:new_checkout, client: { platform: "android", version: "1.4" }))
        .to have_attributes(value: false, reason: "ERROR", error_code: "PARSE_ERROR")
    end
  end

  describe "percentage and variants" do
    it "serves the rollout to units whose bucket is below percentage_bps" do
      with_rule(:new_checkout, percentage: 2_500, fallthrough: false)
      inside = account_id("new_checkout", 2_500, inside: true)
      outside = account_id("new_checkout", 2_500, inside: false)
      expect(evaluate(:new_checkout, inside)).to have_attributes(value: true, reason: "SPLIT", rule_id: "percentage")
      expect(evaluate(:new_checkout, outside)).to have_attributes(value: false, rule_id: "fallthrough")
    end

    it "serves nobody at 0 and everybody at 10,000" do
      with_rule(:new_checkout, percentage: 0)
      expect((1..50).map { |id| evaluate(:new_checkout, id).value }.uniq).to eq([ false ])
      with_rule(:new_checkout, percentage: 10_000)
      expect((1..50).map { |id| evaluate(:new_checkout, id).value }.uniq).to eq([ true ])
    end

    it "serves a mode's rollout value" do
      with_rule(:strict_gates, percentage: 10_000, rollout: :sensor)
      expect(evaluate(:strict_gates)).to have_attributes(value: :sensor, rule_id: "percentage")
    end

    it "picks variants by the variant bucket, in declared order" do
      with_rule(:home_hero, variants: { "privacy" => 5_000, "control" => 5_000 })
      ids = (1..40).to_a
      expected = ids.map { |id| StandardFlags::Bucket.v2("variant", "home_hero", id.to_s) < 5_000 ? "control" : "privacy" }
      expect(ids.map { |id| evaluate(:home_hero, id).value }).to eq(expected)
      expect(evaluate(:home_hero)).to have_attributes(reason: "SPLIT", rule_id: "variants")
    end

    it "gates variants behind the percentage" do
      with_rule(:home_hero, percentage: 1_000, variants: { "savings" => 10_000 })
      inside = account_id("home_hero", 1_000, inside: true)
      outside = account_id("home_hero", 1_000, inside: false)
      expect(evaluate(:home_hero, inside)).to have_attributes(value: "savings", rule_id: "variants")
      expect(evaluate(:home_hero, outside)).to have_attributes(value: "control", reason: "DEFAULT")
    end

    it "uses v1 for both decisions on hash_version 1" do
      with_rule(:home_hero, hash_version: 1, salt: "legacy", variants: { "control" => 5_000, "savings" => 5_000 })
      with_rule(:new_checkout, hash_version: 1, salt: "legacy", percentage: 5_000)
      (1..30).each do |id|
        in_first_half = StandardFlags::Bucket.v1("legacy", id.to_s) < 5_000
        expect(evaluate(:home_hero, id).value).to eq(in_first_half ? "control" : "savings")
        expect(evaluate(:new_checkout, id).value).to eq(in_first_half)
      end
    end

    it "defaults the salt and version to the flag's bucketing:" do
      define_flags do
        unit :account, from: ->(ctx) { ctx.account }
        flag :migrated, owner: "growth", remove_by: "2027-01-01", final: true, unit: :account,
                        bucketing: { version: 1, salt: "old_key" }
      end
      with_rule(:migrated, percentage: 5_000)
      expect(StandardFlags::Testing.runtime_store.rule(:migrated)).to have_attributes(hash_version: 1, salt: "old_key")
      (1..30).each do |id|
        expect(evaluate(:migrated, id).value).to eq(StandardFlags::Bucket.v1("old_key", id.to_s) < 5_000)
      end
    end
  end

  describe "fallthrough" do
    it "serves the fallthrough value with no unit needed" do
      with_rule(:global_banner, fallthrough: true)
      expect(StandardFlags.evaluate(:global_banner)).to have_attributes(value: true, reason: "TARGETING_MATCH", rule_id: "fallthrough")
    end

    it "reads a kill switch thrown from the database as KILL_SWITCH" do
      with_rule(:ai_assistant, fallthrough: false)
      expect(evaluate(:ai_assistant)).to have_attributes(value: false, reason: "KILL_SWITCH", rule_id: "fallthrough")
    end

    it "serves the code default when a running rule has no fallthrough" do
      with_rule(:new_checkout)
      expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "DEFAULT", rule_id: nil)
    end
  end

  describe "a missing unit key" do
    it "serves the fallthrough with TARGETING_KEY_MISSING, notifying without reporting" do
      with_rule(:new_checkout, percentage: 10_000, fallthrough: true)
      events = nil
      errors = collect_errors do
        events = capture_events(/targeting_key_missing/) do
          expect(StandardFlags.evaluate(:new_checkout))
            .to have_attributes(value: true, reason: "ERROR", error_code: "TARGETING_KEY_MISSING", rule_id: "fallthrough")
        end
      end
      expect(events.map(&:last)).to eq([ { key: :new_checkout, unit: :account } ])
      expect(errors.reports).to be_empty
    end

    it "serves the code default when there is no fallthrough" do
      with_rule(:new_checkout, percentage: 10_000)
      expect(StandardFlags.evaluate(:new_checkout, for: { account: Struct.new(:id).new(" ") }))
        .to have_attributes(value: false, reason: "ERROR", error_code: "TARGETING_KEY_MISSING", rule_id: nil)
    end
  end

  describe "invalid stored values" do
    let(:store) { StandardFlags::Testing.runtime_store }

    before { with_rule(:global_banner, fallthrough: true) }

    it "fails only that flag with PARSE_ERROR, reporting once" do
      store.put_rule(:new_checkout, status: :running, fallthrough_value: "maybe")
      errors = collect_errors do
        2.times { expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "ERROR", error_code: "PARSE_ERROR") }
      end
      expect(errors.errors_of(StandardFlags::RuleInvalid).map(&:message))
        .to eq([ "runtime rule for :new_checkout has \"maybe\" in fallthrough_value, not one of on/off" ])
      expect(StandardFlags.evaluate(:global_banner).value).to be(true)
    end

    it "rejects what a rule can't serve" do
      {
        strict_gates: { percentage_bps: 10_000 },
        home_hero: { variant_weights: { "control" => 6_000, "savings" => 3_000 } },
        new_checkout: { percentage_bps: 20_000 }
      }.each do |key, attributes|
        store.put_rule(key, status: :running, **attributes)
        expect(evaluate(key)).to have_attributes(reason: "ERROR", error_code: "PARSE_ERROR")
      end
      store.put_rule(:ai_assistant, status: :running, hash_version: 3, percentage_bps: 5)
      expect(evaluate(:ai_assistant)).to have_attributes(value: true, error_code: "PARSE_ERROR")
    end
  end

  describe "precedence" do
    it "lets an ENV pin and a test override beat the rule" do
      with_rule(:new_checkout, fallthrough: true)
      set_env("STANDARD_FLAGS_NEW_CHECKOUT" => "off")
      expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "ENV_PIN")
      set_env({})
      with_flag(:new_checkout, false)
      expect(evaluate(:new_checkout)).to have_attributes(value: false, reason: "STATIC")
    end

    it "keeps forbidden_in: above the database" do
      define_flags { flag :demo, owner: "web", remove_by: "2027-01-01", final: false, forbidden_in: :production }
      with_rule(:demo, fallthrough: true)
      expect(StandardFlags.evaluate(:demo, for: StandardFlags::Context.new(env: "production")).reason).to eq("DISABLED")
      expect(StandardFlags.evaluate(:demo, for: StandardFlags::Context.new(env: "staging")).value).to be(true)
    end
  end
end
