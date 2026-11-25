require "spec_helper"
require "rack/test"

RSpec.describe StandardFlags::Controller do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def get_json(path, headers = {})
    get path, {}, { "HTTP_ACCEPT" => "application/json" }.merge(headers)
  end

  def json
    JSON.parse(last_response.body)
  end

  let(:android_1_5) { { "HTTP_X_CLIENT_PLATFORM" => "Android", "HTTP_X_CLIENT_VERSION" => "1.5.0", "HTTP_X_CLIENT_BUILD" => "150" } }

  before do
    define_flags do
      unit :account, from: ->(ctx) { ctx.account }
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, unit: :account,
                          expose: { mobile: :checkoutV2 }
    end
    with_rule(:new_checkout, percentage: 10_000, fallthrough: false, platforms: %w[android], versions: { android: ">=1.4.0" },
                             builds: { android: ">=120" })
  end

  it "reads the client headers into the request's context" do
    get_json "/client/features", android_1_5
    expect(json).to eq("features" => { "checkoutV2" => true },
                       "client" => { "platform" => "android", "version" => "1.5.0", "build" => "150" })
  end

  it "behaves as before when no header is sent" do
    get_json "/client/features"
    expect(json).to eq("features" => { "checkoutV2" => false }, "client" => {})
  end

  it "treats a build below the range, or a bad version, as unmet" do
    get_json "/client/features", android_1_5.merge("HTTP_X_CLIENT_BUILD" => "119")
    expect(json["features"]).to eq("checkoutV2" => false)
    get_json "/client/features", android_1_5.merge("HTTP_X_CLIENT_VERSION" => "1.5.0.1")
    expect(json).to eq("features" => { "checkoutV2" => false }, "client" => { "platform" => "android", "build" => "150" })
  end

  it "ignores the headers when read_client_headers is off" do
    StandardFlags.config.read_client_headers = false
    get_json "/client/features", android_1_5
    expect(json).to eq("features" => { "checkoutV2" => false }, "client" => {})
  end

  it "keeps a client the app's context already names" do
    get "/client/pinned", {}, android_1_5
    expect(last_response.status).to eq(403)
    with_rule(:new_checkout, percentage: 10_000, fallthrough: false, platforms: %w[ios])
    get "/client/pinned", {}, android_1_5
    expect([ last_response.status, last_response.body ]).to eq([ 200, "pinned" ])
  end

  it "renders a raised FeatureDisabled like a requires_flag denial" do
    get_json "/client/checkout"
    expect(last_response.status).to eq(403)
    expect(json).to eq("errors" => [ { "status" => "403", "code" => "feature_disabled", "meta" => { "feature" => "checkoutV2" } } ])
    get "/client/checkout"
    expect([ last_response.status, last_response.body ]).to eq([ 403, "" ])
    get_json "/client/checkout", android_1_5
    expect([ last_response.status, last_response.body ]).to eq([ 200, "checkout" ])
  end

  it "evaluates for no one by default, with the request's client" do
    controller = Class.new(ActionController::Base) { include StandardFlags::Controller }.new
    controller.request = ActionDispatch::Request.new(Rack::MockRequest.env_for("/", "HTTP_X_CLIENT_PLATFORM" => "ios"))
    context = controller.send(:standard_flags_request_context)
    expect([ controller.send(:standard_flags_context), context.actors, context.client.to_h ]).to eq([ nil, {}, { platform: "ios" } ])
  end

  it "answers a raised FeatureDisabled with status 404 like error: :not_found, revealing no feature" do
    get_json "/client/raise"
    expect([ last_response.status, json ]).to eq([ 404, { "errors" => [ { "status" => "404", "code" => "not_found" } ] } ])
  end

  describe "an app's own rescue_from" do
    it "doesn't swallow FeatureDisabled when it rescues StandardError after the include" do
      get_json "/rescuing/disabled"
      expect([ last_response.status, json.dig("errors", 0, "code") ]).to eq([ 403, "feature_disabled" ])
      expect(RescuingController.new.handler_for_rescue(StandardFlags::FeatureDisabled.new(:new_checkout)).name)
        .to eq(:standard_flags_feature_disabled)
      get "/rescuing/boom"
      expect([ last_response.status, last_response.body ]).to eq([ 500, "app 500" ])
    end

    it "takes FeatureDisabled over when it names it" do
      get "/targeted/disabled"
      expect([ last_response.status, last_response.body ]).to eq([ 451, "own checkoutV2" ])
    end
  end

  it "renders nothing more when the action already has" do
    get "/client/late"
    expect([ last_response.status, last_response.body ]).to eq([ 200, "late" ])
  end

  it "gives actions a reader for the request's context" do
    get "/client/reader", {}, android_1_5
    expect(last_response.body).to eq("true")
    get "/client/reader"
    expect(last_response.body).to eq("false")
  end

  it "builds the payload without a request, as 0.2.2 did" do
    controller = Class.new(ActionController::Base) { include StandardFlags::Controller }.new
    expect([ controller.standard_flags_payload(:mobile), controller.send(:standard_flags_client) ])
      .to eq([ { "checkoutV2" => false }, {} ])
  end

  it "survives client headers holding invalid UTF-8" do
    get_json "/client/features", "HTTP_X_CLIENT_PLATFORM" => "\xFFios".dup.force_encoding("UTF-8"),
                                 "HTTP_X_CLIENT_VERSION" => "\xFF1.5.0".dup.force_encoding("UTF-8"), "HTTP_X_CLIENT_BUILD" => "\xFF".b
    expect([ last_response.status, json ]).to eq([ 200, { "features" => { "checkoutV2" => false }, "client" => { "platform" => "unknown" } } ])
  end

  it "holds a misspelt platform header to every platform-scoped condition" do
    with_rule(:new_checkout, percentage: 10_000, fallthrough: false, versions: { android: ">=9.0.0" })
    get_json "/client/features", "HTTP_X_CLIENT_PLATFORM" => "andriod", "HTTP_X_CLIENT_VERSION" => "1.0.0"
    expect(json["features"]).to eq("checkoutV2" => false)
    get_json "/client/features", "HTTP_X_CLIENT_VERSION" => "1.0.0" # no platform: the range is android's only, as in 0.2.2
    expect(json["features"]).to eq("checkoutV2" => true)
  end

  it "sends a raised FeatureDisabled through config.controller_responder" do
    StandardFlags.config.controller_responder = lambda do |controller, denial|
      controller.render json: { error: { code: denial.error.to_s.upcase, feature: denial.feature } }, status: denial.status
    end
    get_json "/client/checkout"
    expect([ last_response.status, json ]).to eq([ 403, { "error" => { "code" => "FEATURE_DISABLED", "feature" => "checkoutV2" } } ])
  end
end
