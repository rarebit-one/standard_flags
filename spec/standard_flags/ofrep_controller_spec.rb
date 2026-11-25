require "spec_helper"
require "rack/test"

RSpec.describe StandardFlags::OFREP::Controller do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def evaluate(path, body: { context: {} }, headers: {}, token: "acct-1")
    env = { "CONTENT_TYPE" => "application/json" }
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    post path, body.is_a?(String) ? body : JSON.generate(body), env.merge(headers)
  end

  def json
    JSON.parse(last_response.body)
  end

  def flags
    json.fetch("flags").to_h { |entry| [ entry.fetch("key"), entry.except("key") ] }
  end

  let(:android) { { "HTTP_X_CLIENT_PLATFORM" => "android", "HTTP_X_CLIENT_VERSION" => "0.5.0" } }

  before do
    define_flags do
      unit :account, from: ->(ctx) { ctx.account }
      kill_switch :ai, owner: "assistant", expose: { mobile: %i[chat_enabled insights_enabled], web: :ai }
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account,
                          expose: { mobile: :checkoutV2 }, min_client: { android: "0.4.0" }
      flag :internal_only, owner: "platform", remove_by: "2027-01-01", final: true
      tombstone :chat_v1, removed: "2026-01-01", serve: { mobile: { chat_v1: false } }, until: "2099-01-01"
    end
  end

  describe "POST /ofrep/v1/evaluate/flags" do
    it "answers OFREP entries for the audience, aliases and static wires included" do
      evaluate "/ofrep/v1/evaluate/flags", headers: android
      expect(last_response.status).to eq(200)
      expect(flags).to eq(
        "chat_enabled" => { "value" => true, "reason" => "DEFAULT", "variant" => "on" },
        "chat_v1" => { "value" => false, "reason" => "STATIC", "variant" => "off" },
        "checkoutV2" => { "value" => false, "reason" => "DEFAULT", "variant" => "off" },
        "insights_enabled" => { "value" => true, "reason" => "DEFAULT", "variant" => "on" }
      )
      expect(json.fetch("metadata")).to eq("version" => last_response.headers["ETag"].delete('"'))
    end

    it "sends an ETag, no-cache, private and a Vary on authorization and the client headers" do
      evaluate "/ofrep/v1/evaluate/flags"
      expect(last_response.headers["ETag"]).to match(/\A"\h{64}"\z/)
      expect(last_response.headers["Cache-Control"]).to eq("no-cache, private")
      # Rails appends its own (Accept, X-Requested-With) after the action.
      expect(last_response.headers["Vary"]).to start_with("Authorization, X-Client-Platform, X-Client-Version, X-Client-Build")
    end

    it "merges its Vary with one the app already set" do
      evaluate "/api/ofrep/v1/evaluate/flags"
      expect(last_response.headers["Vary"])
        .to start_with("Accept-Encoding, accept, Authorization, X-Client-Platform, X-Client-Version, X-Client-Build")
    end

    it "answers 304 with no body when If-None-Match names the ETag" do
      evaluate "/ofrep/v1/evaluate/flags", headers: android
      etag = last_response.headers["ETag"]
      evaluate "/ofrep/v1/evaluate/flags", headers: android.merge("HTTP_IF_NONE_MATCH" => etag)
      expect([ last_response.status, last_response.body ]).to eq([ 304, "" ])
      expect(last_response.headers["ETag"]).to eq(etag)
      evaluate "/ofrep/v1/evaluate/flags", headers: android.merge("HTTP_IF_NONE_MATCH" => "W/#{etag}, \"other\"")
      expect(last_response.status).to eq(304)
    end

    it "answers 200 again once the answers change" do
      evaluate "/ofrep/v1/evaluate/flags"
      etag = last_response.headers["ETag"]
      set_env("STANDARD_FLAGS_AI" => "off")
      evaluate "/ofrep/v1/evaluate/flags", headers: { "HTTP_IF_NONE_MATCH" => etag }
      expect(last_response.status).to eq(200)
      expect(flags["chat_enabled"]).to eq("value" => false, "reason" => "KILL_SWITCH", "variant" => "off")
    end

    it "never answers one user's ETag with 304 for another whose answers differ" do
      with_members(:new_checkout, %w[acct-a])
      evaluate "/ofrep/v1/evaluate/flags", headers: android, token: "acct-a"
      etag = last_response.headers["ETag"]
      expect(flags["checkoutV2"]["value"]).to be(true)

      evaluate "/ofrep/v1/evaluate/flags", headers: android.merge("HTTP_IF_NONE_MATCH" => etag), token: "acct-b"
      expect(last_response.status).to eq(200)
      expect(flags["checkoutV2"]["value"]).to be(false)
      expect(last_response.headers["ETag"]).not_to eq(etag)
    end

    it "takes units from the authentication, never from targetingKey" do
      with_members(:new_checkout, %w[acct-a])
      evaluate "/ofrep/v1/evaluate/flags", body: { context: { targetingKey: "acct-a" } }, headers: android, token: "acct-b"
      expect(flags["checkoutV2"]["value"]).to be(false)
    end

    it "reads client attributes from the body, with headers winning field by field" do
      evaluate "/ofrep/v1/evaluate/flags", body: { context: { platform: "android", appVersion: "0.3.0" } }
      expect(flags).not_to have_key("checkoutV2")

      evaluate "/ofrep/v1/evaluate/flags", body: { context: { platform: "android", app_version: "0.4.0" } }
      expect(flags).to have_key("checkoutV2")

      evaluate "/ofrep/v1/evaluate/flags", body: { context: { platform: "android", appVersion: "0.4.0" } },
                                           headers: { "HTTP_X_CLIENT_VERSION" => "0.3.9" }
      expect(flags).not_to have_key("checkoutV2")
    end

    it "treats an unrecognised platform, from a header or the body, as an unknown build" do
      evaluate "/ofrep/v1/evaluate/flags", headers: android.merge("HTTP_X_CLIENT_PLATFORM" => "tv")
      expect(flags).not_to have_key("checkoutV2")
      evaluate "/ofrep/v1/evaluate/flags", body: { context: { platform: "tv", appVersion: "9.0.0" } }
      expect(flags).not_to have_key("checkoutV2")
      expect(flags).to have_key("chat_v1")
    end

    it "leaves the authentication to the app" do
      evaluate "/ofrep/v1/evaluate/flags", token: nil
      expect(last_response.status).to eq(401)
    end
  end

  describe "malformed bodies" do
    {
      "not JSON" => "{",
      "not an object" => "[]",
      "no context" => "{}",
      "a context that isn't an object" => '{"context":"x"}',
      "a non-string platform" => '{"context":{"platform":1}}',
      "a non-string targetingKey" => '{"context":{"targetingKey":42}}'
    }.each do |label, body|
      it "answers 400 INVALID_CONTEXT for #{label}" do
        evaluate "/ofrep/v1/evaluate/flags", body: body
        expect(last_response.status).to eq(400)
        expect(json.keys).to eq(%w[errorCode errorDetails])
        expect(json["errorCode"]).to eq("INVALID_CONTEXT")
      end
    end

    it "answers 400 for an oversized body" do
      evaluate "/ofrep/v1/evaluate/flags", body: { context: { padding: "x" * StandardFlags::OFREP::MAX_BODY_BYTES } }
      expect([ last_response.status, json["errorCode"] ]).to eq([ 400, "INVALID_CONTEXT" ])
    end

    it "answers 400 in the single-flag shape, with the key" do
      evaluate "/ofrep/v1/evaluate/flags/chat_enabled", body: "{"
      expect(last_response.status).to eq(400)
      expect(json).to include("key" => "chat_enabled", "errorCode" => "INVALID_CONTEXT")
    end

    it "answers 400 when the app's own filters parse the body first" do
      evaluate "/api/ofrep/v1/evaluate/flags", body: "{"
      expect([ last_response.status, json["errorCode"] ]).to eq([ 400, "INVALID_CONTEXT" ])
    end

    it "drops a client attribute that fails validation, as for headers" do
      events = capture_events(/client_invalid/) do
        evaluate "/ofrep/v1/evaluate/flags", body: { context: { platform: "android", appVersion: "0.5" * 3 } }
      end
      expect(last_response.status).to eq(200)
      expect(flags).not_to have_key("checkoutV2")
      expect(events.map(&:last)).to include(field: :version, header: "appVersion")
    end
  end

  describe "POST /ofrep/v1/evaluate/flags/:key" do
    it "answers one entry by wire name" do
      evaluate "/ofrep/v1/evaluate/flags/insights_enabled"
      expect([ last_response.status, json ])
        .to eq([ 200, { "key" => "insights_enabled", "value" => true, "reason" => "DEFAULT", "variant" => "on" } ])
      expect(last_response.headers["Cache-Control"]).to eq("no-cache, private")
    end

    it "answers a static wire" do
      evaluate "/ofrep/v1/evaluate/flags/chat_v1"
      expect(json).to eq("key" => "chat_v1", "value" => false, "reason" => "STATIC", "variant" => "off")
    end

    it "answers 404 for server-only keys, other audiences' wires and flag keys" do
      %w[internal_only ai new_checkout nonexistent].each do |key|
        evaluate "/ofrep/v1/evaluate/flags/#{key}"
        expect([ last_response.status, json ])
          .to eq([ 404, { "key" => key, "errorCode" => "FLAG_NOT_FOUND", "errorDetails" => "flag #{key} was not found" } ])
      end
    end

    it "answers 404 for a flag the client is too old (or unknown) for" do
      evaluate "/ofrep/v1/evaluate/flags/checkoutV2"
      expect(last_response.status).to eq(404)
      evaluate "/ofrep/v1/evaluate/flags/checkoutV2", headers: android
      expect(last_response.status).to eq(200)
    end

    it "answers 400 with the error code for a flag whose evaluation failed" do
      allow(StandardFlags::Resolvers::CHAIN.last).to receive(:call).and_raise("boom")
      evaluate "/ofrep/v1/evaluate/flags/chat_enabled"
      expect([ last_response.status, json ]).to eq([ 400, { "key" => "chat_enabled", "errorCode" => "GENERAL",
                                                              "errorDetails" => StandardFlags::Delivery::ERROR_DETAILS } ])
    end
  end

  describe "anonymous (pre-auth) controllers" do
    before do
      StandardFlags.config.audiences = { mobile: {}, web: {}, pre_auth: { public: true, unit: :install } }
      define_flags do
        unit :account, from: ->(ctx) { ctx.account }
        unit :install, from: ->(_ctx) { raise "the install unit's own resolver is never called pre-auth" }
        flag :signup_v2, owner: "growth", remove_by: "2027-01-01", final: true, unit: :install, expose: { pre_auth: :signupV2 }
        flag :login_banner, owner: "growth", remove_by: "2027-01-01", final: true, expose: { pre_auth: :loginBanner },
                            min_client: { ios: "2.0.0" }
        flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account,
                            expose: { mobile: :checkoutV2 }
      end
    end

    it "serves only the public audience, without asking who is signed in" do
      evaluate "/pre-auth/ofrep/v1/evaluate/flags", token: nil, headers: { "HTTP_X_CLIENT_PLATFORM" => "android" }
      expect(last_response.status).to eq(200)
      expect(flags.keys).to eq(%w[loginBanner signupV2])
    end

    it "targets the declared install unit by targetingKey" do
      with_members(:signup_v2, %w[install-1])
      evaluate "/pre-auth/ofrep/v1/evaluate/flags", token: nil, body: { context: { targetingKey: "install-1" } }
      expect(flags["signupV2"]).to include("value" => true, "reason" => "TARGETING_MATCH")
      evaluate "/pre-auth/ofrep/v1/evaluate/flags", token: nil, body: { context: { targetingKey: "install-2" } }
      expect(flags["signupV2"]["value"]).to be(false)
    end

    it "keeps every other flag invisible" do
      evaluate "/pre-auth/ofrep/v1/evaluate/flags/checkoutV2", token: nil
      expect(last_response.status).to eq(404)
    end

    it "refuses an over-long targetingKey" do
      evaluate "/pre-auth/ofrep/v1/evaluate/flags", token: nil, body: { context: { targetingKey: "k" * 257 } }
      expect([ last_response.status, json["errorCode"] ]).to eq([ 400, "INVALID_CONTEXT" ])
    end
  end

  it "raises when a controller forgets standard_flags_ofrep" do
    request = StandardFlags::OFREP::Request.new(client: StandardFlags::Client.empty, targeting_key: nil)
    expect { OfrepUnconfiguredController.new.send(:standard_flags_ofrep_result, request) }
      .to raise_error(StandardFlags::Error, /needs `standard_flags_ofrep audience: \.\.\.`/)
  end

  it "rejects a non-boolean anonymous:" do
    expect { Class.new(ActionController::API) { include StandardFlags::OFREP::Controller }.standard_flags_ofrep(audience: :x, anonymous: "yes") }
      .to raise_error(ArgumentError, /anonymous:/)
  end

  describe "the embed helper" do
    it "returns the same body as the bulk endpoint" do
      get "/bootstrap", {}, android
      embedded = JSON.parse(last_response.body).fetch("features")
      evaluate "/ofrep/v1/evaluate/flags", headers: android
      expect(embedded).to eq(json)
      expect(embedded.fetch("flags").map { |entry| entry["key"] }).to eq(%w[chat_enabled chat_v1 checkoutV2 insights_enabled])
    end
  end
end
