require "spec_helper"
require "standard_flags/open_feature"

RSpec.describe StandardFlags::OpenFeature::Provider, registry: OpenFeatureHelpers::REGISTRY do
  include OpenFeatureHelpers

  # Every reason the gem can give, as a setup for one flag of each kind (or
  # only the kinds listed in `kinds:`) and the evaluation context to fetch
  # with. `rule_id` and `error_code` are what the provider must report.
  scenarios = {
    "STATIC (test override)" => {
      reason: "STATIC", setup: ->(key, served) { StandardFlags::Testing.override(key, served) }
    },
    "STATIC (stopped rule)" => {
      reason: "STATIC", rule_id: "stopped",
      setup: ->(key, served) { with_rule(key, status: :stopped, stop: served) }
    },
    "DEFAULT" => { reason: "DEFAULT", setup: ->(*) { } },
    "ENV_PIN" => {
      reason: "ENV_PIN", source_env_var: true,
      setup: lambda { |key, served|
        StandardFlags.config.env_source = { "STANDARD_FLAGS_#{key.upcase}" => StandardFlags::Runtime.wire(served) }
      }
    },
    "KILL_SWITCH (pin)" => {
      reason: "KILL_SWITCH", kinds: %i[kill_switch], source_env_var: true,
      setup: ->(key, _) { StandardFlags.config.env_source = { "STANDARD_FLAGS_#{key.upcase}" => "off" } }
    },
    "KILL_SWITCH (rule)" => {
      reason: "KILL_SWITCH", kinds: %i[kill_switch], rule_id: "fallthrough",
      setup: ->(key, _) { with_rule(key, fallthrough: false) }
    },
    "DISABLED (forbidden_in)" => {
      reason: "DISABLED", context: { targeting_key: "7", env: "qa" },
      setup: ->(*) { @provider = described_class.new(allow_env_override: true) }
    },
    "TARGETING_MATCH (allow)" => {
      reason: "TARGETING_MATCH", rule_id: "allow",
      setup: ->(key, served) { with_members(key, "7", value: served) }
    },
    "TARGETING_MATCH (fallthrough)" => {
      reason: "TARGETING_MATCH", rule_id: "fallthrough",
      setup: ->(key, served) { with_rule(key, fallthrough: served) }
    },
    "SPLIT" => {
      reason: "SPLIT", rule_id: "percentage",
      setup: ->(key, served) { with_rule(key, percentage: 10_000, rollout: served) }
    },
    "ERROR (TARGETING_KEY_MISSING)" => {
      reason: "ERROR", error_code: "TARGETING_KEY_MISSING", context: {},
      setup: ->(key, served) { with_rule(key, percentage: 10_000, rollout: served) }
    },
    "ERROR (PARSE_ERROR)" => {
      reason: "ERROR", error_code: "PARSE_ERROR",
      setup: lambda { |key, _|
        with_rule(:global_banner, fallthrough: true)
        StandardFlags::Testing.runtime_store.put_rule(key, status: :running, fallthrough_value: "maybe")
      }
    },
    "ERROR (GENERAL)" => {
      reason: "ERROR", error_code: "GENERAL",
      setup: lambda { |key, served|
        StandardFlags.config.segment_resolver = ->(*) { raise "segment service down" }
        with_rule(key, segments: { beta: served })
      }
    }
  }

  describe "the kind × fetch type × reason table" do
    around { |example| collect_errors { example.run } }

    OpenFeatureHelpers::KINDS.each do |kind, flag|
      context "with a #{kind}" do
        scenarios.each do |name, scenario|
          next if scenario[:kinds] && !scenario[:kinds].include?(kind)

          context "when the reason is #{name}" do
            before { instance_exec(flag[:key], flag[:served], &scenario[:setup]) }

            let(:of_fields) { scenario.fetch(:context, { targeting_key: "7" }) }
            let(:expected) do
              fields = of_fields
              actors = fields[:targeting_key] ? { account: fields[:targeting_key] } : {}
              StandardFlags.evaluate(flag[:key], for: StandardFlags::Context.new(actors: actors, env: fields[:env]))
            end

            OpenFeatureHelpers::DEFAULTS.each_key do |type|
              if type == flag[:fetch]
                it "fetch_#{type}_value serves the evaluation" do
                  details = fetch(type, flag[:key], of_context(**of_fields))
                  metadata = { "kind" => kind.to_s, "rule_id" => scenario[:rule_id] }
                  metadata["source_env_var"] = "STANDARD_FLAGS_#{flag[:key].upcase}" if scenario[:source_env_var]
                  expect(resolution(details)).to eq(
                    value: wire_value(expected.value), variant: expected.variant, reason: scenario[:reason],
                    error_code: scenario[:error_code], error_message: nil, flag_metadata: metadata.compact
                  )
                  expect(expected).to have_attributes(reason: scenario[:reason], error_code: scenario[:error_code])
                end
              else
                it "fetch_#{type}_value returns the default with TYPE_MISMATCH" do
                  details = fetch(type, flag[:key], of_context(**of_fields))
                  expect(details).to have_attributes(
                    value: OpenFeatureHelpers::DEFAULTS.fetch(type), variant: nil, reason: "ERROR",
                    error_code: "TYPE_MISMATCH", flag_metadata: { "kind" => kind.to_s }
                  )
                  expect(details.error_message).to eq(
                    "flag :#{flag[:key]} is a #{kind}; fetch it as #{flag[:fetch]}, not #{type}"
                  )
                end
              end
            end
          end
        end
      end
    end
  end

  describe "values" do
    it "serves booleans, mode names and variants in the SDK's types" do
      StandardFlags::Testing.override(:strict_gates, :sensor)
      StandardFlags::Testing.override(:home_hero, "privacy")
      StandardFlags::Testing.override(:new_checkout, true)
      expect(fetch(:boolean, :new_checkout)).to have_attributes(value: true, variant: "on")
      expect(fetch(:string, :strict_gates)).to have_attributes(value: "sensor", variant: "sensor")
      expect(fetch(:string, :home_hero)).to have_attributes(value: "privacy", variant: "privacy")
    end

    it "passes ENV_PIN and KILL_SWITCH through as custom reasons" do
      StandardFlags.config.env_source = { "STANDARD_FLAGS_AI_ASSISTANT" => "off", "STANDARD_FLAGS_NEW_CHECKOUT" => "on" }
      expect(fetch(:boolean, :ai_assistant)).to have_attributes(value: false, reason: "KILL_SWITCH")
      expect(fetch(:boolean, :new_checkout)).to have_attributes(value: true, reason: "ENV_PIN")
    end

    it "reports a type mismatch once and never raises, even when strict" do
      StandardFlags.config.strict = true
      errors = collect_errors { 2.times { fetch(:boolean, :strict_gates) } }
      expect(errors.errors_of(StandardFlags::TypeMismatch).map(&:message))
        .to eq([ "flag :strict_gates is a mode; fetch it as string, not boolean" ])
    end
  end

  describe "unknown keys" do
    it "returns the default with FLAG_NOT_FOUND even when strict" do
      StandardFlags.config.strict = true
      expect(resolution(fetch(:boolean, :nope, default: true))).to eq(
        value: true, variant: nil, reason: "ERROR", error_code: "FLAG_NOT_FOUND",
        error_message: "unknown flag :nope; declare it in config/flags.rb", flag_metadata: {}
      )
    end

    it "names a tombstone's removal date and reports once" do
      errors = collect_errors { 2.times { fetch(:string, :old_banner) } }
      expect(fetch(:string, :old_banner))
        .to have_attributes(value: "fallback", error_code: "FLAG_NOT_FOUND", error_message: "flag :old_banner was removed on 2026-01-01")
      expect(errors.errors_of(StandardFlags::UnknownFlag).size).to eq(1)
    end

    it "stops recording distinct unknown keys at the report registry's cap" do
      stub_const("StandardFlags::Reporting::LIMIT", 3)
      events = nil
      errors = collect_errors { events = capture_events { 5.times { |i| fetch(:boolean, :"nope_#{i}") } } }
      expect(errors.errors_of(StandardFlags::UnknownFlag).size).to eq(3)
      expect(events.map(&:first)).to eq(%w[report_registry_full.standard_flags])
      expect(fetch(:boolean, :nope_9)).to have_attributes(error_code: "FLAG_NOT_FOUND")
    end

    it "treats keys that aren't flag keys as unknown" do
      [ "New-Checkout", "", nil ].each do |key|
        details = provider.fetch_boolean_value(flag_key: key, default_value: true)
        expect(details).to have_attributes(value: true, error_code: "FLAG_NOT_FOUND")
      end
    end
  end

  describe "the evaluation context" do
    it "uses targeting_key as the key of the flag's unit" do
      with_members(:new_checkout, "acct-7")
      expect(fetch(:boolean, :new_checkout, of_context(targeting_key: "acct-7")))
        .to have_attributes(value: true, reason: "TARGETING_MATCH", flag_metadata: { "kind" => "flag", "rule_id" => "allow" })
      expect(fetch(:boolean, :new_checkout, of_context(targeting_key: "acct-8"))).to have_attributes(value: false)
    end

    it "lets a field named after the unit override targeting_key for that unit only" do
      with_members(:org_billing, "org-1")
      with_members(:new_checkout, "user-9")
      context = of_context(targeting_key: "user-9", organization: "org-1")
      expect(fetch(:boolean, :org_billing, context)).to have_attributes(value: true, reason: "TARGETING_MATCH")
      expect(fetch(:boolean, :new_checkout, context)).to have_attributes(value: true, reason: "TARGETING_MATCH")
      expect(fetch(:boolean, :org_billing, of_context(targeting_key: "org-1", organization: "org-2")))
        .to have_attributes(value: false)
    end

    it "uses keys as given, without the unit's from: or key:" do
      with_members(:beta, Struct.new(:phone).new("+6590000000"))
      expect(fetch(:boolean, :beta, of_context(targeting_key: "+6590000000")))
        .to have_attributes(value: true, reason: "TARGETING_MATCH")
      expect(fetch(:boolean, :beta, of_context(user: "+6590000000"))).to have_attributes(value: true)
    end

    it "reads an Integer or Symbol key as its string" do
      with_members(:new_checkout, "42")
      expect(fetch(:boolean, :new_checkout, of_context(targeting_key: 42))).to have_attributes(value: true)
      expect(fetch(:boolean, :new_checkout, of_context(account: :"42"))).to have_attributes(value: true)
    end

    it "treats a blank key as missing" do
      with_rule(:new_checkout, percentage: 10_000, rollout: true)
      expect(fetch(:boolean, :new_checkout, of_context(targeting_key: "  ")))
        .to have_attributes(value: false, error_code: "TARGETING_KEY_MISSING")
    end

    it "returns the default with INVALID_CONTEXT for a key that isn't a scalar" do
      details = fetch(:boolean, :new_checkout, of_context(account: { "id" => 7 }), default: true)
      expect(resolution(details)).to eq(
        value: true, variant: nil, reason: "ERROR", error_code: "INVALID_CONTEXT",
        error_message: "context field account must be a string key, not a Hash", flag_metadata: { "kind" => "flag" }
      )
    end

    it "maps platform, appVersion / app_version and build to the client" do
      seen = []
      StandardFlags.config.segment_resolver = ->(_, context) { seen << context and nil }
      with_rule(:new_checkout, segments: { beta: true })
      fetch(:boolean, :new_checkout, of_context(targeting_key: "7", platform: "ios", appVersion: "2.1.0", build: "381", env: "staging"))
      fetch(:boolean, :new_checkout, of_context(targeting_key: "7", app_version: "1.4.0", platform: " "))
      expect(seen.map { |context| [ context.client, context.env ] }).to eq([
        [ { platform: "ios", version: "2.1.0", build: "381" }, nil ],
        [ { version: "1.4.0" }, nil ]
      ])
    end

    it "validates only the evaluated flag's own unit field" do
      with_members(:org_billing, "org-1")
      structured = { "id" => 1 }
      expect(fetch(:boolean, :global_banner, of_context(user: structured, account: 1.5, organization: Time.now)))
        .to have_attributes(reason: "DEFAULT", error_code: nil)
      expect(fetch(:boolean, :org_billing, of_context(targeting_key: "org-1", user: 1.5, account: structured)))
        .to have_attributes(value: true, reason: "TARGETING_MATCH", error_code: nil)
      expect(fetch(:boolean, :org_billing, of_context(organization: true)))
        .to have_attributes(error_code: "INVALID_CONTEXT", error_message: "context field organization must be a string key, not a TrueClass")
    end

    it "validates targeting_key only when it is the flag's unit key" do
      structured = { "id" => 7 }
      expect(fetch(:boolean, :new_checkout, of_context(targeting_key: structured)))
        .to have_attributes(error_code: "INVALID_CONTEXT", error_message: "context field targeting_key must be a string key, not a Hash")
      expect(fetch(:boolean, :global_banner, of_context(targeting_key: structured))).to have_attributes(error_code: nil)
      expect(fetch(:boolean, :org_billing, of_context(targeting_key: structured, organization: "org-1")))
        .to have_attributes(error_code: nil)
    end

    it "passes other units' scalar keys to the segment resolver and drops the rest" do
      seen = []
      StandardFlags.config.segment_resolver = ->(_, context) { seen << context.actors and nil }
      with_rule(:new_checkout, segments: { beta: true })
      fetch(:boolean, :new_checkout, of_context(targeting_key: "7", organization: "org-1", user: { "id" => 1 }))
      expect(seen).to eq([ { account: "7", organization: "org-1" } ])
    end

    describe "env" do
      def production_registry
        StandardFlags.define do
          env_resolver { "production" }
          flag :danger, owner: "platform", permanent: true, forbidden_in: %w[production]
          flag :regional, owner: "platform", permanent: true, default: { "staging" => true }
        end
        StandardFlags.config.env_source = { "STANDARD_FLAGS_DANGER" => "on" }
      end

      it "is ignored by default, so a context can't relax a guard or pick another environment's default" do
        production_registry
        expect(fetch(:boolean, :danger, of_context(env: "prod"))).to have_attributes(value: false, reason: "DISABLED")
        expect(fetch(:boolean, :regional, of_context(env: "staging"))).to have_attributes(value: false, reason: "DEFAULT")
      end

      it "overrides the environment with allow_env_override: true, but never relaxes a guard" do
        production_registry
        @provider = described_class.new(allow_env_override: true)
        expect(fetch(:boolean, :regional, of_context(env: "staging"))).to have_attributes(value: true, reason: "DEFAULT")
        expect(fetch(:boolean, :danger, of_context(env: "prod"))).to have_attributes(value: false, reason: "DISABLED")
      end

      it "takes allow_env_override: as true or false only" do
        expect { described_class.new(allow_env_override: "yes") }
          .to raise_error(ArgumentError, "allow_env_override: must be true or false")
      end
    end

    it "targets client conditions through them" do
      with_rule(:new_checkout, platforms: %w[ios], versions: { ios: ">= 2.0" }, percentage: 10_000, rollout: true)
      expect(fetch(:boolean, :new_checkout, of_context(targeting_key: "7", platform: "ios", appVersion: "2.1")))
        .to have_attributes(value: true, reason: "SPLIT")
      expect(fetch(:boolean, :new_checkout, of_context(targeting_key: "7", platform: "ios", app_version: "1.9")))
        .to have_attributes(value: false, reason: "DEFAULT")
    end

    it "works with no context" do
      expect(provider.fetch_string_value(flag_key: "strict_gates", default_value: "x"))
        .to have_attributes(value: "off", reason: "DEFAULT")
    end
  end

  describe "the registry" do
    it "follows a redefinition" do
      expect(fetch(:boolean, :new_checkout)).to have_attributes(value: false)
      StandardFlags.define do
        flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, default: true
        flag :later, owner: "payments", remove_by: "2027-01-01", final: true, default: true
      end
      expect(fetch(:boolean, :new_checkout)).to have_attributes(value: true)
      expect(fetch(:boolean, :later)).to have_attributes(value: true)
    end

    it "builds its keyed copy once per registry" do
      allow(StandardFlags::Registry).to receive(:new).and_call_original
      3.times { fetch(:boolean, :new_checkout, of_context(targeting_key: "7")) }
      expect(StandardFlags::Registry).to have_received(:new).once
    end

    it "keeps the registry's environment" do
      StandardFlags.define do
        env_resolver { "qa" }
        flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, forbidden_in: %w[qa]
      end
      expect(fetch(:boolean, :new_checkout)).to have_attributes(reason: "DISABLED")
    end
  end

  describe "failures" do
    it "returns the default with GENERAL when evaluation itself raises, reporting once" do
      allow(StandardFlags::Reader).to receive(:new).and_raise(ArgumentError, "boom")
      errors = collect_errors do
        2.times do
          expect(resolution(fetch(:boolean, :new_checkout, default: true))).to eq(
            value: true, variant: nil, reason: "ERROR", error_code: "GENERAL",
            error_message: "ArgumentError while evaluating new_checkout", flag_metadata: { "kind" => "flag" }
          )
        end
      end
      expect(errors.errors_of(ArgumentError).map(&:message)).to eq([ "boom" ])
    end

    it "maps an error code it doesn't know to GENERAL" do
      evaluation = StandardFlags::Evaluation.new(
        key: :new_checkout, value: false, variant: "off", reason: "ERROR", error_code: "SOMETHING_NEW",
        rule_id: nil, source_env_var: nil
      )
      allow(StandardFlags::Reader).to receive(:new).and_return(instance_double(StandardFlags::Reader, evaluate: evaluation))
      expect(fetch(:boolean, :new_checkout)).to have_attributes(reason: "ERROR", error_code: "GENERAL")
    end
  end

  describe "provider interface" do
    it "is named standard_flags, has no hooks, and needs no init" do
      expect(provider.metadata).to have_attributes(name: "standard_flags")
      expect(provider.hooks).to eq([])
      expect(provider.shutdown).to be_nil
      expect(provider).not_to respond_to(:init)
    end

    it "answers every fetch the SDK client makes" do
      OpenFeature::SDK::Client::RESULT_TYPE.each do |type|
        expect(provider).to respond_to(:"fetch_#{type}_value")
      end
    end
  end
end
