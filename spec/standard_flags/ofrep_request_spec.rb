require "spec_helper"
require "rack/test"

# How the OFREP mixin treats the request itself: forgery protection, the
# media type, the body read, and an app's own error handling.
RSpec.describe StandardFlags::OFREP::Controller do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def evaluate(path, body: { context: {} }, headers: {}, token: "acct-1", content_type: "application/json")
    env = {}
    env["CONTENT_TYPE"] = content_type if content_type
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    post path, body.is_a?(String) ? body : JSON.generate(body), env.merge(headers)
  end

  def json
    JSON.parse(last_response.body)
  end

  def flags
    json.fetch("flags").to_h { |entry| [ entry.fetch("key"), entry.except("key") ] }
  end

  let(:long_wire) { "w" * 230 }

  before do
    wire = long_wire
    define_flags do
      unit :account, from: ->(ctx) { ctx.account }
      kill_switch :ai, owner: "assistant", expose: { mobile: :chat_enabled }
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, expose: { mobile: :checkoutV2 },
                          min_client: { android: "0.4.0" }
      flag :long_named, owner: "platform", remove_by: "2027-01-01", final: true, expose: { mobile: wire }
    end
  end

  describe "forgery protection" do
    around do |example|
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = previous
    end

    it "serves a bearer-token JSON request with csrf: :skip" do
      evaluate "/ofrep/v1/evaluate/flags"
      expect(last_response.status).to eq(200)
      expect(flags).to have_key("chat_enabled")
    end

    it "keeps Rails' check with csrf: :protect" do
      evaluate "/csrf/ofrep/v1/evaluate/flags"
      expect(last_response.status).to eq(422)
    end

    it "answers a non-JSON request 415 before the CSRF check" do
      evaluate "/csrf/ofrep/v1/evaluate/flags", content_type: "text/plain"
      expect([ last_response.status, json["errorCode"] ]).to eq([ 415, "INVALID_CONTEXT" ])
    end

    it "refuses a protected controller with no csrf: choice when it is declared" do
      expect do
        Class.new(DummyBaseController) do
          include StandardFlags::OFREP::Controller
          standard_flags_ofrep audience: :mobile
        end
      end.to raise_error(StandardFlags::ConfigurationError, /forgery protection: declare .*csrf: :skip.*csrf: :protect/)
    end

    it "refuses it on the first request when protection is declared after the mixin" do
      expect { OfrepLateCsrfController.standard_flags_ofrep_check_csrf! }.to raise_error(StandardFlags::ConfigurationError)
      expect { OfrepLateCsrfController.action(:ofrep_evaluate_flags).call(Rack::MockRequest.env_for("/", method: "POST")) }
        .to raise_error(StandardFlags::ConfigurationError)
    end

    it "needs no choice on an API controller, and refuses an unknown one" do
      expect { Class.new(ActionController::API) { include StandardFlags::OFREP::Controller }.standard_flags_ofrep(audience: :x) }
        .not_to raise_error
      expect { Class.new(ActionController::API) { include StandardFlags::OFREP::Controller }.standard_flags_ofrep(audience: :x, csrf: :off) }
        .to raise_error(ArgumentError, /csrf: must be :skip or :protect/)
    end
  end

  describe "the media type" do
    [ "text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", nil ].each do |type|
      it "answers 415 for #{type.inspect}" do
        evaluate "/ofrep/v1/evaluate/flags", content_type: type
        expect([ last_response.status, json ]).to eq([ 415, { "errorCode" => "INVALID_CONTEXT",
                                                               "errorDetails" => "Content-Type must be application/json" } ])
      end
    end

    it "accepts application/json with a charset, and answers the single path 415 with its key" do
      evaluate "/ofrep/v1/evaluate/flags", content_type: "application/json; charset=utf-8"
      expect(last_response.status).to eq(200)
      evaluate "/ofrep/v1/evaluate/flags/chat_enabled", content_type: "text/plain"
      expect([ last_response.status, json["key"] ]).to eq([ 415, "chat_enabled" ])
    end
  end

  describe "the body" do
    it "refuses an oversized body before Rails decodes it" do
      allow(ActiveSupport::JSON).to receive(:decode).and_call_original
      evaluate "/ofrep/v1/evaluate/flags", body: { context: { padding: "x" * StandardFlags::OFREP::MAX_BODY_BYTES } }
      expect([ last_response.status, json["errorCode"] ]).to eq([ 400, "INVALID_CONTEXT" ])
      expect(ActiveSupport::JSON).not_to have_received(:decode)
    end

    it "reads at most the limit when no Content-Length is declared" do
      input = StringIO.new("{" + (" " * (StandardFlags::OFREP::MAX_BODY_BYTES * 4)) + "}")
      env = Rack::MockRequest.env_for("/", method: "POST", "CONTENT_TYPE" => "application/json", input: input)
      env.delete("CONTENT_LENGTH")
      expect { StandardFlags::OFREP.read(ActionDispatch::Request.new(env)) }
        .to raise_error(StandardFlags::OFREP::InvalidRequest, /larger than 65536 bytes/)
    end

    it "hands Rails the body it read, so the app's filters still see the params" do
      env = Rack::MockRequest.env_for("/", method: "POST", "CONTENT_TYPE" => "application/json",
                                           input: '{"context":{"platform":"ios"}}')
      request = ActionDispatch::Request.new(env)
      StandardFlags::OFREP.read(request)
      expect(request.request_parameters).to eq("context" => { "platform" => "ios" })
    end

    it "answers invalid UTF-8 with OFREP's 400, on both kinds of controller" do
      StandardFlags.config.audiences = { mobile: {}, pre_auth: { public: true } }
      define_flags { kill_switch :ai, owner: "assistant", expose: { mobile: :chat_enabled, pre_auth: :ai } }
      body = "{\"context\":{\"platform\":\"\xFF\"}}".b
      [ "/ofrep/v1/evaluate/flags", "/pre-auth/ofrep/v1/evaluate/flags" ].each do |path|
        evaluate path, body: body
        expect([ last_response.status, json ])
          .to eq([ 400, { "errorCode" => "INVALID_CONTEXT", "errorDetails" => "the request body is not valid UTF-8" } ])
      end
    end

    it "checks only the property a client field is read from" do
      evaluate "/ofrep/v1/evaluate/flags", body: { context: { platform: "android", appVersion: "1.0.0", app_version: 5 } }
      expect(last_response.status).to eq(200)
      expect(flags).to have_key("checkoutV2")
    end
  end

  describe "an app's rescue_from StandardError" do
    it "can't turn a malformed or non-JSON request into a 5xx" do
      evaluate "/rescuing/ofrep/v1/evaluate/flags", body: "{"
      expect([ last_response.status, json["errorCode"] ]).to eq([ 400, "INVALID_CONTEXT" ])
      evaluate "/rescuing/ofrep/v1/evaluate/flags", content_type: "text/plain"
      expect(last_response.status).to eq(415)
      evaluate "/rescuing/ofrep/v1/evaluate/flags"
      expect(last_response.status).to eq(200)
    end
  end

  it "takes no client from the body when read_client_headers is off" do
    StandardFlags.config.read_client_headers = false
    evaluate "/ofrep/v1/evaluate/flags", body: { context: { platform: "android", appVersion: "1.0.0" } },
                                         headers: { "HTTP_X_CLIENT_PLATFORM" => "android", "HTTP_X_CLIENT_VERSION" => "1.0.0" }
    expect(flags).not_to have_key("checkoutV2")
  end

  describe "single-flag keys and caching" do
    it "looks a key up untruncated, and answers an over-long key 404 echoing only its start" do
      evaluate "/ofrep/v1/evaluate/flags/#{long_wire}"
      expect([ last_response.status, json["key"] ]).to eq([ 200, long_wire ])
      evaluate "/ofrep/v1/evaluate/flags/#{long_wire[0, 200]}"
      expect(last_response.status).to eq(404)
      key = "chat_enabled#{'x' * 300}"
      evaluate "/ofrep/v1/evaluate/flags/#{key}"
      expect([ last_response.status, json["key"] ]).to eq([ 404, key[0, 200] ])
    end

    it "sends a strong ETag over the one entry and honours If-None-Match" do
      evaluate "/ofrep/v1/evaluate/flags/chat_enabled"
      etag = last_response.headers["ETag"]
      expect(etag).to match(/\A"\h{64}"\z/)
      entry = StandardFlags::Delivery::Entry.evaluated("chat_enabled", true, "on", "DEFAULT")
      expect(etag).to eq(%("#{StandardFlags::Delivery.etag(:mobile, [ entry ])}"))
      evaluate "/ofrep/v1/evaluate/flags/chat_enabled", headers: { "HTTP_IF_NONE_MATCH" => etag }
      expect([ last_response.status, last_response.body ]).to eq([ 304, "" ])
    end
  end
end
