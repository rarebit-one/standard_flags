require "spec_helper"
require "standard_flags/open_feature"
require "open_feature/sdk/isolated"

# The provider behind a real SDK client, on an isolated API so nothing leaks
# into the global one.
RSpec.describe StandardFlags::OpenFeature::Provider, registry: OpenFeatureHelpers::REGISTRY do
  include OpenFeatureHelpers

  let(:api) { OpenFeature::SDK::Isolated.create_api }
  let(:client) { api.build_client }

  before { api.configure { |config| config.set_provider_and_wait(provider) } }
  after { api.shutdown }

  it "is ready as soon as it is set, with no lifecycle warning" do
    logger = instance_double(Logger, warn: nil)
    other = OpenFeature::SDK::Isolated.create_api
    other.configure do |config|
      config.logger = logger
      config.set_provider_and_wait(described_class.new)
    end
    expect(other.build_client.provider_status).to eq(OpenFeature::SDK::ProviderState::READY)
    expect(other.provider_metadata).to have_attributes(name: "standard_flags")
    expect(logger).not_to have_received(:warn)
    other.shutdown
  end

  it "returns details with the variant, the reason and flag metadata" do
    with_members(:new_checkout, "7")
    details = client.fetch_boolean_details(flag_key: "new_checkout", default_value: false,
                                           evaluation_context: of_context(targeting_key: "7"))
    expect(details).to have_attributes(value: true, variant: "on", reason: "TARGETING_MATCH", error_code: nil,
                                       flag_metadata: { "kind" => "flag", "rule_id" => "allow" })
  end

  it "merges the API's context with the invocation's" do
    with_members(:org_billing, "org-1")
    api.configure { |config| config.evaluation_context = of_context(organization: "org-1") }
    expect(client.fetch_boolean_value(flag_key: "org_billing", default_value: false,
                                      evaluation_context: of_context(targeting_key: "user-9"))).to be(true)
  end

  it "keeps the custom reasons" do
    StandardFlags.config.env_source = { "STANDARD_FLAGS_AI_ASSISTANT" => "off" }
    expect(client.fetch_boolean_details(flag_key: "ai_assistant", default_value: true))
      .to have_attributes(value: false, reason: "KILL_SWITCH", flag_metadata: include("source_env_var" => "STANDARD_FLAGS_AI_ASSISTANT"))
  end

  it "serves the caller's default on an error, including the flag's fail value" do
    with_rule(:ai_assistant, percentage: 10_000, rollout: false)
    expect(StandardFlags.evaluate(:ai_assistant)).to have_attributes(value: true, error_code: "TARGETING_KEY_MISSING")
    expect(client.fetch_boolean_details(flag_key: "ai_assistant", default_value: false))
      .to have_attributes(value: false, reason: "ERROR", error_code: "TARGETING_KEY_MISSING")
  end

  it "reads modes and experiments as strings and mismatches without raising" do
    StandardFlags::Testing.override(:strict_gates, :sensor)
    expect(client.fetch_string_value(flag_key: "strict_gates", default_value: "off")).to eq("sensor")
    expect(client.fetch_boolean_details(flag_key: "strict_gates", default_value: false))
      .to have_attributes(value: false, error_code: "TYPE_MISMATCH")
    expect(client.fetch_object_details(flag_key: "home_hero", default_value: {}))
      .to have_attributes(value: {}, error_code: "TYPE_MISMATCH")
  end

  it "returns FLAG_NOT_FOUND for an unknown key in strict mode" do
    StandardFlags.config.strict = true
    expect(client.fetch_string_details(flag_key: "nope", default_value: "x"))
      .to have_attributes(value: "x", error_code: "FLAG_NOT_FOUND", error_message: "unknown flag :nope; declare it in config/flags.rb")
  end
end
