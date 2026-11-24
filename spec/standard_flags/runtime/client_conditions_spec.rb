require "spec_helper"

RSpec.describe StandardFlags::Runtime::Resolver, registry: RuntimeHelpers::REGISTRY do
  describe "client conditions in the neutral syntax, and build ranges" do
    def evaluate(client)
      StandardFlags.evaluate(:new_checkout, for: for_account(1, client: client))
    end

    it "reads neutral ranges, alternatives and prereleases" do
      with_rule(:new_checkout, percentage: 10_000, fallthrough: false, versions: { android: ">=1.4.0 <2.0.0 || =0.9.5-beta.1" })
      met = [ "1.4", "1.9.9-rc.1", "0.9.5-beta.1", "1.4.0+381" ]
      unmet = [ "2.0.0", "0.9.5", "1.3.9", "1.4.0.1" ]
      expect(met.map { |v| evaluate(platform: "android", version: v).rule_id }).to all(eq("percentage"))
      expect(unmet.map { |v| evaluate(platform: "android", version: v).rule_id }).to all(eq("fallthrough"))
    end

    it "needs the version and the build range to hold when both are set" do
      with_rule(:new_checkout, percentage: 10_000, fallthrough: false, versions: { android: ">=1.4" }, builds: { android: ">=120 <200" })
      expect(evaluate(platform: "android", version: "1.5.0", build: "150")).to have_attributes(value: true, rule_id: "percentage")
      [ { version: "1.5.0", build: "200" }, { version: "1.3.0", build: "150" }, { version: "1.5.0" }, { version: "1.5.0", build: "x" } ].each do |client|
        expect(evaluate(platform: "android", **client).rule_id).to eq("fallthrough")
      end
      expect(evaluate(platform: "ios", version: "0.1").rule_id).to eq("percentage") # no range for ios
      expect(evaluate({}).rule_id).to eq("percentage") # no platform: as 0.2.2 treats a versions-only rule
    end

    it "takes a build range alone, and a build from a Client" do
      with_rule(:new_checkout, percentage: 10_000, fallthrough: false, platforms: %w[ios], builds: { ios: "=7 || >=12" })
      expect([ 7, 12, 99 ].map { |b| evaluate(StandardFlags::Client.new(platform: "ios", build: b)).rule_id }).to all(eq("percentage"))
      expect(evaluate(platform: "ios", build: 8).rule_id).to eq("fallthrough")
    end

    it "fails only the flag on a malformed build range" do
      with_rule(:new_checkout, percentage: 10_000, builds: { android: ">= 1.4.0" })
      errors = collect_errors do
        expect(evaluate(platform: "android", build: "1")).to have_attributes(value: false, reason: "ERROR", error_code: "PARSE_ERROR")
        expect(StandardFlags.evaluate(:global_banner)).to have_attributes(reason: "DEFAULT")
      end
      expect(errors.errors_of(StandardFlags::RuleInvalid).map(&:message))
        .to eq([ 'runtime rule for :new_checkout has an invalid build range ">= 1.4.0"' ])
    end

    it "fails the flag on builds stored as something other than an object" do
      with_rule(:new_checkout, percentage: 10_000)
      StandardFlags::Testing.runtime_store.put_rule(:new_checkout, status: :running, percentage_bps: 10_000, conditions: { "builds" => ">=1" })
      StandardFlags::Memo.clear!
      expect(evaluate(platform: "android", build: "1")).to have_attributes(reason: "ERROR", error_code: "PARSE_ERROR")
    end
  end

  describe "client conditions as 0.2.2 read them" do
    def evaluate(client)
      StandardFlags.evaluate(:new_checkout, for: for_account(1, client: client))
    end

    it "skips per-platform ranges for a client with no platform, but fails a platform list" do
      with_rule(:new_checkout, percentage: 10_000, fallthrough: false, versions: { android: ">=9.0.0" })
      expect([ evaluate({}).rule_id, evaluate(version: "1.0.0").rule_id ]).to eq(%w[percentage percentage])
      with_rule(:new_checkout, percentage: 10_000, fallthrough: false, platforms: %w[android])
      expect(evaluate({}).rule_id).to eq("fallthrough")
    end

    it "fails every platform-scoped condition for an unknown platform" do
      { { versions: { android: ">=9.0.0" } } => "a version range", { builds: { android: ">=1" } } => "a build range",
        { platforms: %w[android] } => "a platform list" }.each_key do |conditions|
        with_rule(:new_checkout, percentage: 10_000, fallthrough: false, **conditions)
        expect(evaluate(platform: "unknown", version: "10.0.0", build: "5").rule_id).to eq("fallthrough")
      end
      with_rule(:new_checkout, percentage: 10_000, fallthrough: false)
      expect(evaluate(platform: "unknown").rule_id).to eq("percentage") # no client conditions at all
    end

    it "reads non-SemVer client versions through RubyGems against RubyGems-readable ranges" do
      with_rule(:new_checkout, percentage: 10_000, fallthrough: false, versions: { android: ">= 1.4.0" })
      expect(%w[1.4.0.1 1.4.0.beta 01.4.0].map { |v| evaluate(platform: "android", version: v).rule_id })
        .to eq(%w[percentage fallthrough percentage])
      expect([ Gem::Version.new("1.4.2"), 1.5 ].map { |v| evaluate(platform: "android", version: v).rule_id }).to all(eq("percentage"))
    end

    it "evaluates a stored range the neutral syntax can't hold through RubyGems, not as an error" do
      with_rule(:new_checkout, percentage: 10_000, fallthrough: false, versions: { android: "~> 1.4.2.1" })
      expect(%w[1.4.2.1 1.4.2.9 1.4.3].map { |v| evaluate(platform: "android", version: v).rule_id })
        .to eq(%w[percentage percentage fallthrough])
    end

    it "keeps the client a Hash for segment resolvers and units" do
      seen = []
      StandardFlags.config.segment_resolver = ->(_name, context) { seen << context.client.fetch(:platform, nil) and false }
      with_rule(:new_checkout, segments: { beta: true })
      evaluate(platform: "ios")
      evaluate({})
      expect(seen).to eq([ "ios", nil ])
    end
  end
end
