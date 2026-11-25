require "spec_helper"
require "rack/test"

# GET /client/status (StandardFlags::ClientStatus::Controller) and the 426
# guard (StandardFlags::Controller.requires_client_version), through the
# dummy app's controllers in spec/support/dummy_controllers.rb.
RSpec.describe StandardFlags::Controller, ".requires_client_version" do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def client(platform, version = nil, build = nil)
    { "HTTP_X_CLIENT_PLATFORM" => platform, "HTTP_X_CLIENT_VERSION" => version, "HTTP_X_CLIENT_BUILD" => build }.compact
  end

  def get_json(path, headers = {})
    get path, {}, { "HTTP_ACCEPT" => "application/json" }.merge(headers)
  end

  def json
    JSON.parse(last_response.body)
  end

  before do
    StandardFlags.define do
      client :android_app, platform: :android, min_version: "0.4.0", since: "2026-11-01", recommended: "0.5.0",
                           available: "0.5.0", store_url: "https://example.com/store/android"
      client :ios_app, platform: :ios, min_version: "2.0.0", since: "2099-01-01"
      client :kiosk_android, platform: :android, group: :kiosk, min_version: "1.2.0", since: "2026-11-01", grace: 0
    end
  end

  describe "GET /client/status" do
    it "answers the status payload, privately cacheable for a minute, varying on the client headers" do
      get_json "/client/status", client("android", "0.3.0")
      expect(last_response.status).to eq(200)
      expect(json).to eq("status" => "upgrade_required", "platform" => "android", "version" => "0.3.0", "min_version" => "0.4.0",
                         "recommended" => "0.5.0", "enforce_at" => "2026-11-08", "store_url" => "https://example.com/store/android")
      expect(last_response.headers["Cache-Control"]).to eq("max-age=60, private")
      expect(last_response.headers["Vary"]).to include("X-Client-Platform, X-Client-Version, X-Client-Build")
      expect(last_response.media_type).to eq("application/json")
    end

    it "answers every status with 200" do
      { client("android", "0.4.0") => "upgrade_recommended", client("android", "0.5.0") => "ok",
        client("ios", "1.0.0") => "upgrade_recommended", {} => "unknown", client("Android", "0.3") => "upgrade_required",
        client("palm", "1.0.0") => "unknown", client("android", "1.0.0.1") => "unknown" }.each do |headers, expected|
        get "/client/status", {}, headers
        expect([ last_response.status, json["status"] ]).to eq([ 200, expected ]), headers.inspect
      end
    end

    it "is pre-auth: it never asks who is signed in, and works with forgery protection on" do
      ActionController::Base.allow_forgery_protection = true
      get "/client/status", {}, client("android", "0.5.0")
      expect(json["status"]).to eq("ok")
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    it "works on an API controller, keeping its Vary and the default options" do
      get "/api/client/status", {}, client("ios", "1.0.0")
      expect(json).to include("status" => "upgrade_recommended", "enforce_at" => "2099-01-08")
      expect(last_response.headers["Vary"]).to start_with("Accept-Encoding, X-Client-Platform")
      expect(last_response.headers["Cache-Control"]).to eq("max-age=60, private")
    end

    it "answers for its group, with its own max_age" do
      get "/kiosk/client/status", {}, client("android", "1.1.0")
      expect(json).to include("status" => "upgrade_required", "min_version" => "1.2.0")
      expect(last_response.headers["Cache-Control"]).to eq("max-age=5, private")
    end

    it "can't see the client when read_client_headers is off" do
      StandardFlags.config.read_client_headers = false
      get "/client/status", {}, client("android", "0.3.0")
      expect(json["status"]).to eq("unknown")
    end

    it "follows config.client_headers" do
      StandardFlags.config.client_headers = { platform: "X-App-Os", version: "X-App-Version" }
      get "/client/status", {}, { "HTTP_X_APP_OS" => "android", "HTTP_X_APP_VERSION" => "0.5.0" }
      expect(json["status"]).to eq("ok")
      expect(last_response.headers["Vary"]).to include("X-App-Os, X-App-Version")
    end

    it "refuses a bad max_age" do
      klass = Class.new(ActionController::API) { include StandardFlags::ClientStatus::Controller }
      expect { klass.standard_flags_client_status(max_age: -1) }.to raise_error(ArgumentError, /max_age:/)
      expect { klass.standard_flags_client_status(max_age: "60") }.to raise_error(ArgumentError, /max_age:/)
    end
  end

  describe "requires_client_version" do
    let(:unknown_clients) { [ {}, client("android"), client("android", "latest"), client("palm", "1.0.0") ] }

    it "answers 426 client_upgrade_required as JSON:API with min_version and store_url" do
      get_json "/upgrade/orders", client("android", "0.3.9")
      expect(last_response.status).to eq(426)
      expect(json).to eq("errors" => [ { "status" => "426", "code" => "client_upgrade_required",
                                         "meta" => { "min_version" => "0.4.0", "store_url" => "https://example.com/store/android" } } ])
    end

    it "answers a bare 426 to other formats" do
      get "/upgrade/orders", {}, client("android", "0.3.9")
      expect([ last_response.status, last_response.body ]).to eq([ 426, "" ])
    end

    it "passes a client at the minimum, in its grace window, below recommended only, or on an undeclared platform" do
      [ client("android", "0.4.0"), client("ios", "1.0.0"), client("web", "0.0.1"), client("android", "0.5.0", "9") ].each do |headers|
        get "/upgrade/orders", {}, headers
        expect([ last_response.status, last_response.body ]).to eq([ 200, "orders" ]), headers.inspect
      end
    end

    it "passes an unknown platform or version" do
      unknown_clients.each do |headers|
        get "/upgrade/orders", {}, headers
        expect(last_response.status).to eq(200), headers.inspect
      end
    end

    it "refuses an unknown platform or version when config.require_client_version is on" do
      StandardFlags.config.require_client_version = true
      unknown_clients.each do |headers|
        get_json "/upgrade/orders", headers
        expect(last_response.status).to eq(426), headers.inspect
      end
      get_json "/upgrade/orders", client("android")
      expect(json.dig("errors", 0, "meta")).to eq("min_version" => "0.4.0", "store_url" => "https://example.com/store/android")
      get_json "/upgrade/orders", {}
      expect(json.dig("errors", 0, "meta")).to eq("min_version" => nil, "store_url" => nil)
      get "/upgrade/orders", {}, client("web", "1.0.0")
      expect(last_response.status).to eq(200)
    end

    it "honours only:/except:" do
      get "/upgrade/health", {}, client("android", "0.1.0")
      expect([ last_response.status, last_response.body ]).to eq([ 200, "health" ])
    end

    it "answers through with:, handing it an UpgradeDenial" do
      get "/upgrade/own", {}, client("android", "0.3.9")
      expect(last_response.status).to eq(426)
      expect(json).to eq("error" => { "code" => "CLIENT_UPGRADE_REQUIRED", "min" => "0.4.0", "client" => "android_app" })
    end

    it "answers through config.controller_responder" do
      denials = []
      StandardFlags.config.controller_responder = lambda do |controller, denial|
        denials << denial
        controller.render json: { error: { code: denial.error.to_s.upcase } }, status: denial.status
      end
      get "/upgrade/responder", {}, client("android", "0.3.9", "39")
      expect([ last_response.status, json ]).to eq([ 426, { "error" => { "code" => "CLIENT_UPGRADE_REQUIRED" } } ])
      expect(denials.first).to have_attributes(key: :android_app, error: :client_upgrade_required, status: 426, feature: nil,
                                               platform: "android", version: "0.3.9", min_version: "0.4.0",
                                               store_url: "https://example.com/store/android")
      expect(denials.first).to be_a(StandardFlags::Controller::UpgradeDenial)
    end

    it "uses its group's client" do
      get "/upgrade/kiosk", {}, client("android", "1.1.0")
      expect(last_response.status).to eq(426)
      get "/upgrade/kiosk", {}, client("android", "1.2.0")
      expect(last_response.status).to eq(200)
    end

    it "uses a client the app's context names" do
      get "/upgrade/context", {}, client("android", "9.9.9")
      expect(last_response.status).to eq(426)
    end

    it "refuses a with: that can't answer" do
      expect { Class.new(DummyBaseController) { requires_client_version with: "render" } }
        .to raise_error(ArgumentError, /with: must respond to call/)
    end

    it "changes nothing for a controller that doesn't declare it" do
      get "/reports", {}, client("android", "0.0.1")
      expect([ last_response.status, last_response.body ]).to eq([ 200, "index" ])
    end
  end

  describe "a raised ClientUpgradeRequired" do
    it "is answered like the guard" do
      get_json "/upgrade/raise", client("android", "0.3.9")
      expect(last_response.status).to eq(426)
      expect(json.dig("errors", 0, "code")).to eq("client_upgrade_required")
      get "/upgrade/raise", {}, client("android", "0.5.0")
      expect(last_response.body).to eq("ok")
    end

    it "survives an app's rescue_from StandardError declared after the include" do
      get_json "/upgrade/rescuing", client("android", "0.3.9")
      expect(last_response.status).to eq(426)
    end

    it "is left to an app's own rescue_from ClientUpgradeRequired" do
      get "/upgrade/targeted", {}, client("android", "0.3.9")
      expect([ last_response.status, last_response.body ]).to eq([ 400, "own 0.4.0" ])
    end
  end
end
