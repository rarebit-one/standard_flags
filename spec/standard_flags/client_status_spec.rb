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

  it "lets a prerelease of exactly the minimum meet it, but not one of an older version" do
    expect(status({ platform: "android", version: "0.4.0-beta.2" }, today: Date.new(2026, 12, 8)).status).to eq("upgrade_recommended")
    expect(status({ platform: "android", version: "0.3.9-rc.1" }, today: Date.new(2026, 12, 8)).status).to eq("upgrade_required")
    expect(described_class.meets?(StandardFlags::Version.parse("1.0.0-rc.1"), StandardFlags::Version.parse("1.0.0-rc.2"))).to be(false)
  end

  describe "the store ceiling" do
    # Two iOS apps: the consumer app with a lookup, and a second app (group
    # :driver) whose newest store build is 1.4.0.
    def define_ios(lookup)
      StandardFlags.define do
        client :consumer_ios, platform: :ios, min_version: "3.0.0", since: "2026-01-01", available: "2.9.0", store_lookup: lookup
        client :driver_ios, platform: :ios, group: :driver, min_version: "1.5.0", since: "2026-01-01", available: "1.4.0"
      end
    end

    it "caps only the client that declares the lookup" do
      define_ios(->(_app) { "3.0.0" })
      expect(status({ platform: "ios", version: "1.4.0" }, group: :driver).to_h).to include("status" => "ok", "min_version" => "1.4.0")
      expect(status({ platform: "ios", version: "2.9.5" }).to_h).to include("status" => "upgrade_required", "min_version" => "3.0.0")
    end

    it "passes the lookup its own client" do
      seen = []
      define_ios(->(app) { seen << app.name and "2.9.0" })
      status({ platform: "ios", version: "2.9.0" })
      status({ platform: "ios", version: "1.4.0" }, group: :driver)
      expect(seen).to eq([ :consumer_ios ])
    end

    it "lets a pinned _AVAILABLE beat the lookup" do
      define_ios(->(_app) { "3.0.0" })
      StandardFlags.config.env_source = { "STANDARD_FLAGS_CLIENT_CONSUMER_IOS_AVAILABLE" => "0.0.0" }
      expect(status({ platform: "ios", version: "2.0.0" }).to_h).to include("status" => "ok", "min_version" => "0.0.0")
    end

    it "falls back to available: when the lookup fails, answers nonsense or nil, and reports a failure once" do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe("store_lookup_failed.standard_flags") { |*, payload| events << payload }
      { ->(_app) { raise Timeout::Error } => "2.9.0", ->(_app) { "latest" } => "2.9.0", ->(_app) { nil } => "2.9.0",
        ->(_app) { 3 } => "3.0.0" }.each do |lookup, expected|
        define_ios(lookup)
        expect(status({ platform: "ios", version: "1.0.0" }).min_version.to_s).to eq(expected)
      end
      define_ios(->(_app) { raise Timeout::Error })
      2.times { status({ platform: "ios", version: "1.0.0" }) }
      expect(events).to eq([ { store: "Proc", client: :consumer_ios, reason: "Timeout::Error" } ])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "never lifts the minimum above the code's, only caps it" do
      define_ios(->(_app) { "9.0.0" })
      expect(status({ platform: "ios", version: "2.9.0" }).to_h).to include("min_version" => "3.0.0")
    end
  end
end
