require "spec_helper"
require "rack/test"

RSpec.describe StandardFlags::Controller do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def get_json(path)
    get path, {}, { "HTTP_ACCEPT" => "application/json" }
  end

  before do
    define_flags do
      flag :new_reports, owner: "reporting", remove_by: "2027-01-01", final: true, expose: { web: :reportsV2 }
      flag :legacy_export, owner: "reporting", remove_by: "2027-01-01", final: false
      kill_switch :ai_assistant, owner: "assistant"
      mode :strict_gates, owner: "platform", preset: :sensor
    end
  end

  it "lets requests through when the flag is on" do
    with_flag(:new_reports, true) { get "/reports/1" }
    expect([ last_response.status, last_response.body ]).to eq([ 200, "show" ])
  end

  it "skips excepted actions" do
    get "/reports"
    expect(last_response.status).to eq(200)
  end

  it "answers JSON requests with a JSON:API feature_disabled error naming the wire name" do
    get_json "/reports/1"
    expect(last_response.status).to eq(403)
    expect(JSON.parse(last_response.body))
      .to eq("errors" => [ { "status" => "403", "code" => "feature_disabled", "meta" => { "feature" => "reportsV2" } } ])
  end

  it "answers other formats with the bare status" do
    get "/reports/1"
    expect([ last_response.status, last_response.body ]).to eq([ 403, "" ])
  end

  it "keeps a 404 contract with error: :not_found and reveals nothing" do
    get_json "/exports"
    expect(last_response.status).to eq(404)
    expect(JSON.parse(last_response.body)).to eq("errors" => [ { "status" => "404", "code" => "not_found" } ])
  end

  it "takes a custom status and falls back to the key without a wire name" do
    set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off")
    get_json "/assistant"
    expect(last_response.status).to eq(503)
    expect(JSON.parse(last_response.body).dig("errors", 0, "meta", "feature")).to eq("ai_assistant")
  end

  it "treats a mode as enabled past its first value" do
    get "/assistant"
    expect(last_response.status).to eq(403)
    with_mode(:strict_gates, :sensor) { get "/assistant" }
    expect(last_response.status).to eq(200)
  end

  it "uses a configured responder" do
    StandardFlags.config.controller_responder = lambda do |controller, denial|
      controller.render plain: "#{denial.key}:#{denial.error}:#{denial.feature}", status: 418
    end
    get "/reports/1"
    expect([ last_response.status, last_response.body ]).to eq([ 418, "new_reports:feature_disabled:reportsV2" ])
  end

  it "shares the payload for an audience" do
    with_flag(:new_reports, true) { get "/features" }
    expect(JSON.parse(last_response.body)).to eq("features" => { "reportsV2" => true })
  end

  it "rejects an unknown error kind at declaration" do
    expect { Class.new(DummyBaseController) { requires_flag :new_reports, error: :gone } }
      .to raise_error(ArgumentError, /error: must be one of/)
  end

  it "builds the JSON:API body from a denial" do
    denial = StandardFlags::Controller::Denial.new(key: :x, error: :feature_disabled, status: 404, feature: "x")
    expect(denial.body).to eq(errors: [ { status: "404", code: "feature_disabled", meta: { feature: "x" } } ])
  end
end
