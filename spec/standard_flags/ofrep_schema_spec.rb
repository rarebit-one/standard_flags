require "spec_helper"
require "json_schemer"
require "rack/test"
require "yaml"

# Validates what StandardFlags::OFREP serves against the OFREP OpenAPI
# document, vendored unmodified at spec/fixtures/ofrep/openapi.yaml (OFREP
# 0.4.0, open-feature/protocol at 98c4e0de55). Two corrections are applied in
# memory, each pinned below by a check that the unmodified document still
# needs it:
#
# 1. `codeDefaultFlag` is `{ type: object, properties: {} }`, which matches
#    every object, so every entry that carries a value matches two branches
#    of evaluationSuccess's `oneOf` and fails, including the valued entries
#    of the document's own bulk example. It is read as intended ("this schema has no value
#    property"): an object without `value`.
# 2. evaluationSuccess's `reason` enum lists STATIC, TARGETING_MATCH, SPLIT,
#    DISABLED and UNKNOWN, while OpenFeature's resolution reasons (which the
#    field's description points to) are an open set that includes DEFAULT
#    and provider-specific reasons. The gem's DEFAULT, ENV_PIN and
#    KILL_SWITCH are added; nothing else is.
module OfrepSchema
  DOCUMENT = YAML.safe_load_file(File.expand_path("../fixtures/ofrep/openapi.yaml", __dir__)).freeze
  GEM_REASONS = [ StandardFlags::Reason::DEFAULT, StandardFlags::Reason::ENV_PIN, StandardFlags::Reason::KILL_SWITCH ].freeze

  def self.corrected
    document = JSON.parse(JSON.generate(DOCUMENT))
    schemas = document["components"]["schemas"]
    schemas["codeDefaultFlag"] = { "type" => "object", "not" => { "required" => [ "value" ] } }
    schemas["evaluationSuccess"]["allOf"][0]["properties"]["reason"]["enum"] += GEM_REASONS
    document
  end

  RAW = JSONSchemer.openapi(DOCUMENT)
  CORRECTED = JSONSchemer.openapi(corrected)
end

RSpec.describe StandardFlags::OFREP do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def errors(schema, document)
    OfrepSchema::CORRECTED.schema(schema).validate(document).map { |error| error["error"] }
  end

  def evaluate(path, body: { context: { platform: "android", appVersion: "1.0.0" } }, headers: {})
    post path, body.is_a?(String) ? body : JSON.generate(body),
         { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer acct-1" }.merge(headers)
    JSON.parse(last_response.body)
  end

  before do
    define_flags do
      unit :account, from: ->(ctx) { ctx.account }
      kill_switch :ai, owner: "assistant", expose: { mobile: %i[chat_enabled insights_enabled] }
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account,
                          expose: { mobile: :checkoutV2 }, min_client: { android: "0.4.0" }
      mode :strict_gates, owner: "platform", preset: :sensor, expose: { mobile: :gates }
      experiment :home_hero, owner: "growth", variants: %w[control savings], unit: :account, expose: { mobile: :homeHero }
      tombstone :chat_v1, removed: "2026-01-01", serve: { mobile: { chat_v1: false, chatMode: "legacy" } }, until: "2099-01-01"
    end
  end

  describe "the corrections" do
    let(:raw) { OfrepSchema::RAW }
    let(:corrected) { OfrepSchema::CORRECTED }

    it "are still needed: the document rejects the valued entries of its own bulk example" do
      example = OfrepSchema::DOCUMENT.dig("paths", "/ofrep/v1/evaluate/flags", "post", "responses", "200", "content",
                                          "application/json", "example")
      # Its third entry (FLAG_NOT_FOUND) is outside evaluationFailure's own
      # enum too; the gem never sends that code in a bulk response.
      valued = example.merge("flags" => example["flags"].select { |entry| entry.key?("value") })
      expect(valued["flags"].size).to eq(2)
      expect(raw.schema("bulkEvaluationSuccess").valid?(valued)).to be(false)
      expect(corrected.schema("bulkEvaluationSuccess").valid?(valued)).to be(true)
    end

    it "only widen the reason enum by the gem's own reasons" do
      entry = { "key" => "a", "value" => true, "variant" => "on" }
      expect(raw.schema("evaluationSuccess").valid?(entry.merge("reason" => "KILL_SWITCH"))).to be(false)
      expect(corrected.schema("evaluationSuccess").valid?(entry.merge("reason" => "KILL_SWITCH"))).to be(true)
      expect(corrected.schema("evaluationSuccess").valid?(entry.merge("reason" => "ERROR"))).to be(false)
    end
  end

  it "accepts the bodies the gem parses" do
    expect(errors("bulkEvaluationRequest", { "context" => { "targetingKey" => "x", "platform" => "ios", "appVersion" => "1.0.0" } }))
      .to eq([])
  end

  describe "bulk responses" do
    it "validate for every kind, alias and static wire" do
      body = evaluate("/ofrep/v1/evaluate/flags")
      expect(body["flags"].size).to eq(7)
      expect(errors("bulkEvaluationSuccess", body)).to eq([])
    end

    it "validate with KILL_SWITCH, ENV_PIN, SPLIT and TARGETING_MATCH reasons" do
      set_env("STANDARD_FLAGS_AI" => "off", "STANDARD_FLAGS_STRICT_GATES" => "on")
      with_rule(:home_hero, variants: { "control" => 0, "savings" => 10_000 })
      with_members(:new_checkout, %w[acct-1])
      body = evaluate("/ofrep/v1/evaluate/flags")
      expect(body["flags"].map { |entry| entry["reason"] }.uniq.sort)
        .to eq(%w[ENV_PIN KILL_SWITCH SPLIT STATIC TARGETING_MATCH])
      expect(errors("bulkEvaluationSuccess", body)).to eq([])
    end

    it "validate with an errored flag among them" do
      allow(StandardFlags::Resolvers::CHAIN.last).to receive(:call).and_raise("boom")
      body = evaluate("/ofrep/v1/evaluate/flags")
      expect(body["flags"].count { |entry| entry.key?("errorCode") }).to eq(5)
      expect(errors("bulkEvaluationSuccess", body)).to eq([])
    end

    it "validate when empty" do
      body = StandardFlags.payload(:device, format: :ofrep)
      expect(errors("bulkEvaluationSuccess", body)).to eq([])
    end

    it "fail in OFREP's bulk failure shape" do
      expect(errors("bulkEvaluationFailure", evaluate("/ofrep/v1/evaluate/flags", body: "[]"))).to eq([])
    end
  end

  describe "single-flag responses" do
    it "validate on success, for a boolean and a string" do
      expect(errors("serverEvaluationSuccess", evaluate("/ofrep/v1/evaluate/flags/chat_enabled"))).to eq([])
      expect(errors("serverEvaluationSuccess", evaluate("/ofrep/v1/evaluate/flags/gates"))).to eq([])
    end

    it "validate a 404 as flagNotFound and a 400 as evaluationFailure" do
      expect(errors("flagNotFound", evaluate("/ofrep/v1/evaluate/flags/new_checkout"))).to eq([])
      expect(errors("evaluationFailure", evaluate("/ofrep/v1/evaluate/flags/gates", body: "{"))).to eq([])
      allow(StandardFlags::Resolvers::CHAIN.last).to receive(:call).and_raise("boom")
      expect(errors("evaluationFailure", evaluate("/ofrep/v1/evaluate/flags/gates"))).to eq([])
    end
  end
end
