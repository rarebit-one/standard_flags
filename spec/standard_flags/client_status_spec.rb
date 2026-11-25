require "spec_helper"

# The status rules are pinned case by case in conformance/wire/client_status.json
# (spec/wire_conformance_spec.rb); these cover the Ruby API around them.
RSpec.describe StandardFlags::ClientStatus do
  before do
    StandardFlags.define do
      client :android_app, platform: :android, min_version: "0.4.0", since: "2026-12-01", recommended: "0.5.0",
                           available: "0.5.0", store_url: "https://example.com/store/android"
      client :ios_app, platform: :ios, min_version: "2.0.0", since: "2026-11-01", available: "1.9.0"
    end
  end

  let(:today) { Date.new(2026, 12, 3) }

  def status(client, **options)
    described_class.for(client, today: today, **options)
  end

  it "takes a Client or a Hash, and answers a Result" do
    result = status(StandardFlags::Client.new(platform: "android", version: "0.3.0"))
    expect(result).to have_attributes(status: "upgrade_recommended", platform: "android", enforce_at: Date.new(2026, 12, 8),
                                      client_app: StandardFlags.registry.clients[:android_app])
    expect(result).not_to be_upgrade_required
    expect(result).not_to be_unknown
    expect(status({ platform: "android", version: "0.3.0" }, today: Date.new(2026, 12, 8))).to be_upgrade_required
    expect(status(nil)).to be_unknown
  end

  it "defaults to today's UTC date and the configured ENV source" do
    travel = Time.utc(2026, 12, 8, 0, 30)
    allow(Time).to receive(:now).and_return(travel.getlocal("-05:00"))
    expect(described_class.for({ platform: "android", version: "0.3.0" }).status).to eq("upgrade_required")
    StandardFlags.config.env_source = { "STANDARD_FLAGS_CLIENT_ANDROID_APP_SINCE" => "2026-12-05" }
    expect(described_class.for({ platform: "android", version: "0.3.0" }).status).to eq("upgrade_recommended")
  end

  it "reads a client Hash's platform loosely, as Context does" do
    expect(status({ "platform" => " Android ", "version" => "0.5.0" }).status).to eq("ok")
    expect(status({ platform: "unknown", version: "0.5.0" }).to_h).to include("status" => "unknown", "platform" => nil)
  end

  describe "the store ceiling" do
    it "asks a single lookup about iOS clients only" do
      lookup = double("lookup")
      allow(lookup).to receive(:call) { |app| app.platform == "ios" ? "2.0.0" : raise("asked about #{app.name}") }
      StandardFlags.config.client_store_lookup = lookup
      expect(status({ platform: "ios", version: "1.9.5" }).to_h).to include("status" => "upgrade_required", "min_version" => "2.0.0")
      expect(status({ platform: "android", version: "0.3.0" }).to_h).to include("min_version" => "0.4.0")
      expect(lookup).to have_received(:call).once
    end

    it "takes a Hash of client name => lookup" do
      StandardFlags.config.client_store_lookup = { "android_app" => ->(_app) { "0.4.5" } }
      expect(status({ platform: "android", version: "0.4.0" }).to_h).to include("status" => "upgrade_recommended", "recommended" => "0.4.5")
      expect(status({ platform: "ios", version: "1.9.0" }).to_h).to include("min_version" => "1.9.0")
    end

    it "falls back to available: when the lookup fails, answers nonsense or nil, and reports a failure once" do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe("store_lookup_failed.standard_flags") { |*, payload| events << payload }
      { ->(_app) { raise Timeout::Error } => "1.9.0", ->(_app) { "latest" } => "1.9.0", ->(_app) { nil } => "1.9.0",
        ->(_app) { 2 } => "2.0.0" }.each do |lookup, expected|
        expect(status({ platform: "ios", version: "1.9.0" }, lookup: { ios_app: lookup }).min_version.to_s).to eq(expected)
      end
      2.times { status({ platform: "ios", version: "1.9.0" }, lookup: { ios_app: ->(_app) { raise Timeout::Error } }) }
      expect(events).to eq([ { client: :ios_app, error_class: "Timeout::Error" } ])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "never lifts the minimum above the code's, only caps it" do
      result = status({ platform: "android", version: "0.4.0" }, lookup: { android_app: ->(_app) { "9.0.0" } })
      expect(result.to_h).to include("min_version" => "0.4.0", "recommended" => "0.5.0")
    end
  end
end
