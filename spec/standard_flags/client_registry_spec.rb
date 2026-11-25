require "spec_helper"

RSpec.describe StandardFlags::ClientApp do
  def define_clients(&block)
    StandardFlags.define(&block)
  end

  let(:android) do
    { platform: :android, min_version: "0.4.0", since: "2026-12-01", recommended: "0.5.0", available: "0.5.0",
      store_url: "https://example.com/store/android" }
  end

  it "declares clients in config/flags.rb and finds them by platform and group" do
    registry = define_clients do
      client :android_app, platform: :android, min_version: "0.4.0", since: "2026-12-01", grace: 7.days
      client :ios_app, platform: "iOS"
      client :kiosk_android, platform: :android, group: :kiosk, grace: 0
    end

    android = registry.client_for("android")
    expect(android).to have_attributes(name: :android_app, platform: "android", group: nil, grace_days: 7,
                                       min_version: StandardFlags::Version.parse("0.4.0"), since: Date.new(2026, 12, 1))
    expect(registry.client_for(:ios)).to have_attributes(name: :ios_app, grace_days: 7, min_version: nil, since: nil)
    expect(registry.clients.keys).to eq(%i[android_app ios_app kiosk_android])
  end

  it "finds a group's client, and nil for a platform or group with none" do
    registry = define_clients do
      client :android_app, platform: :android
      client :kiosk_android, platform: :android, group: :kiosk, grace: 0
    end
    expect(registry.client_for("android", group: :kiosk)).to have_attributes(name: :kiosk_android, grace_days: 0)
    expect(registry.client_for("android", group: "kiosk").name).to eq(:kiosk_android)
    expect(registry.client_for("web")).to be_nil
    expect(registry.client_for("ios", group: :kiosk)).to be_nil
    expect(registry.clients.values.map(&:inspect))
      .to eq([ "#<StandardFlags::ClientApp :android_app android>", "#<StandardFlags::ClientApp :kiosk_android android (kiosk)>" ])
  end

  it "keeps the clients when the registry is copied for one unit key" do
    registry = define_clients do
      unit :account, from: ->(ctx) { ctx.account }
      client :android_app, platform: :android
    end
    expect(registry.with_unit_key(:account, "1").clients).to eq(registry.clients)
  end

  it "takes grace: as whole days" do
    registry = define_clients do
      client :a, platform: :android, grace: 14
      client :b, platform: :ios, grace: 2.weeks
      client :c, platform: :web, grace: 0.days
    end
    expect(registry.clients.values.map(&:grace_days)).to eq([ 14, 14, 0 ])
  end

  {
    "an unknown platform" => [ { platform: :watch }, /platform: :watch is not one of config.client_platforms/ ],
    "the unknown platform" => [ { platform: "unknown" }, /is not one of config.client_platforms/ ],
    "a bad name" => [ { platform: :android }, /name must match/, "Android-App" ],
    "a bad group" => [ { platform: :android, group: "Kiosk!" }, /group: must match/ ],
    "a min_version that isn't a version" => [ { platform: :android, min_version: "v1", since: "2026-12-01" }, /min_version: "v1" is not a version/ ],
    "a non-String version" => [ { platform: :android, recommended: 1.2 }, /recommended: 1.2 is not a version/ ],
    "a min_version without since" => [ { platform: :android, min_version: "0.4.0" }, /min_version: needs since:/ ],
    "since without a min_version" => [ { platform: :android, since: "2026-12-01" }, /since: needs min_version:/ ],
    "a since that isn't a date" => [ { platform: :android, min_version: "0.4.0", since: "1 Dec" }, /since: "1 Dec" is not a YYYY-MM-DD date/ ],
    "an impossible date" => [ { platform: :android, min_version: "0.4.0", since: "2026-02-30" }, /is not a YYYY-MM-DD date/ ],
    "recommended below the minimum" => [ { platform: :android, min_version: "0.4.0", since: "2026-12-01", recommended: "0.3.0" },
                                         /recommended: 0.3.0 is below min_version: 0.4.0/ ],
    "a partial day of grace" => [ { platform: :android, grace: 36.hours }, /grace: must be a whole number of days/ ],
    "a negative grace" => [ { platform: :android, grace: -1 }, /grace: must be a whole number of days/ ],
    "a grace that isn't a duration" => [ { platform: :android, grace: "7" }, /grace: must be a whole number of days/ ],
    "a store_url that isn't http(s)" => [ { platform: :android, store_url: "market://details?id=x" }, /store_url: must be an http\(s\) URL/ ],
    "a store_url that doesn't parse" => [ { platform: :android, store_url: "https://exa mple.com" }, /store_url: must be an http\(s\) URL/ ],
    "a store_url that isn't a String" => [ { platform: :android, store_url: :store }, /store_url: must be an http\(s\) URL/ ],
    "an unknown attribute" => [ { platform: :android, minimum: "1.0.0" }, /unknown keyword: :minimum/ ]
  }.each do |label, (attributes, message, name)|
    it "refuses #{label}" do
      expect { define_clients { client((name || :android_app), **attributes) } }
        .to raise_error(message.source.start_with?("unknown keyword") ? ArgumentError : StandardFlags::DefinitionError, message)
    end
  end

  it "takes a Time or DateTime since: as its UTC date, so enforce_at stays a date" do
    registry = define_clients do
      client :a, platform: :android, min_version: "1.0.0", since: DateTime.new(2026, 12, 1, 23, 0, 0, "-05:00"), grace: 0
      client :b, platform: :ios, min_version: "1.0.0", since: Time.utc(2026, 12, 1, 18), grace: 0
    end
    expect(registry.clients.values.map(&:since)).to eq([ Date.new(2026, 12, 2), Date.new(2026, 12, 1) ])
    expect(registry.clients.values.map { |app| app.since.class }).to eq([ Date, Date ])
    result = StandardFlags::ClientStatus.for({ platform: "android", version: "0.9.0" }, today: Date.new(2026, 12, 2))
    expect(result.to_h["enforce_at"]).to eq("2026-12-02")
  end

  it "accepts a Date for since and a version with a prerelease" do
    registry = define_clients { client :android_app, platform: :android, min_version: "1.0.0-rc.1", since: Date.new(2026, 12, 1) }
    expect(registry.clients[:android_app]).to have_attributes(since: Date.new(2026, 12, 1), min_version: StandardFlags::Version.parse("1.0.0-rc.1"))
  end

  it "refuses a client declared twice, or two clients on one platform in one group" do
    expect { define_clients { client(:a, platform: :android) && client(:a, platform: :ios) } }
      .to raise_error(StandardFlags::DefinitionError, "client :a is declared twice")
    expect { define_clients { client(:a, platform: :android) && client(:b, platform: :android) } }
      .to raise_error(StandardFlags::DefinitionError, /client :b and client :a are both android in the default group; give one a group:/)
    expect { define_clients { client(:a, platform: :android, group: :kiosk) && client(:b, platform: :android, group: :kiosk) } }
      .to raise_error(StandardFlags::DefinitionError, /both android in group :kiosk/)
  end

  it "refuses a flag whose pin is a client's pin" do
    expect do
      define_clients do
        client :app, platform: :android
        flag :client_app_min_version, owner: "mobile", permanent: true
      end
    end.to raise_error(StandardFlags::DefinitionError,
                       "flag :client_app_min_version's pin STANDARD_FLAGS_CLIENT_APP_MIN_VERSION is client :app's pin; rename one")
  end

  it "follows config.client_platforms" do
    StandardFlags.config.client_platforms = %w[android tv]
    expect(define_clients { client :tv_app, platform: :tv }.client_for("tv").name).to eq(:tv_app)
    expect { define_clients { client :ios_app, platform: :ios } }.to raise_error(StandardFlags::DefinitionError, /not one of/)
  end

  it "names its ENV pins" do
    app = define_clients { client :android_app, platform: :android }.clients[:android_app]
    expect(app.env_vars).to eq(%w[STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION STANDARD_FLAGS_CLIENT_ANDROID_APP_SINCE
                                  STANDARD_FLAGS_CLIENT_ANDROID_APP_RECOMMENDED STANDARD_FLAGS_CLIENT_ANDROID_APP_AVAILABLE])
    expect { app.env_var(:store_url) }.to raise_error(ArgumentError, "no pin for :store_url")
  end

  describe "ENV pins" do
    subject(:app) do
      attributes = android_attributes
      define_clients { client :android_app, **attributes }.clients[:android_app]
    end

    let(:android_attributes) { android }

    def pins(**values)
      values.to_h { |suffix, value| [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_#{suffix.to_s.upcase}", value ] }
    end

    it "uses the code when nothing is pinned" do
      policy = app.resolve({})
      expect(policy).to have_attributes(min_version: app.min_version, since: app.since, recommended: app.recommended,
                                        available: app.available, pinned: [], rejected: [], enforce_on: Date.new(2026, 12, 8))
    end

    it "lets a pin beat the code, field by field" do
      policy = app.resolve(pins(min_version: " 0.4.2 ", since: "2026-12-04", recommended: "0.6", available: "0.6.0"))
      expect([ policy.min_version, policy.recommended, policy.available ].map(&:to_s)).to eq(%w[0.4.2 0.6.0 0.6.0])
      expect([ policy.since, policy.enforce_on ]).to eq([ Date.new(2026, 12, 4), Date.new(2026, 12, 11) ])
      expect(policy.pinned).to eq(app.env_vars)
    end

    it "refuses a raised minimum without a pinned _SINCE, so a break-glass raise can't skip the grace window" do
      policy = app.resolve(pins(min_version: "0.4.5"))
      expect(policy).to have_attributes(min_version: app.min_version, pinned: [], rejected: [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ])
      policy = app.resolve(pins(min_version: "0.4.5", since: "soon"))
      expect(policy.rejected).to eq(%w[STANDARD_FLAGS_CLIENT_ANDROID_APP_SINCE STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION])
    end

    it "takes a lowered (or equal) minimum without _SINCE: it can only relax enforcement" do
      expect(app.resolve(pins(min_version: "0.3.0")).min_version.to_s).to eq("0.3.0")
      expect(app.resolve(pins(min_version: "0.4.0")).pinned).to eq([ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ])
    end

    it "ignores blank pins and rejects ones that don't parse" do
      policy = app.resolve(pins(min_version: "", since: "soon", recommended: "latest", available: "1.2.3.4"))
      expect(policy).to have_attributes(min_version: app.min_version, since: app.since, recommended: app.recommended,
                                        available: app.available, pinned: [])
      expect(policy.rejected).to eq(%w[STANDARD_FLAGS_CLIENT_ANDROID_APP_SINCE STANDARD_FLAGS_CLIENT_ANDROID_APP_RECOMMENDED
                                       STANDARD_FLAGS_CLIENT_ANDROID_APP_AVAILABLE])
    end

    context "without a minimum in the code" do
      let(:android_attributes) { { platform: :android } }

      it "ignores a pinned minimum without a since, and takes one with it" do
        policy = app.resolve(pins(min_version: "1.0.0"))
        expect(policy).to have_attributes(min_version: nil, pinned: [], rejected: [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ])
        policy = app.resolve(pins(min_version: "1.0.0", since: "2026-12-01"))
        expect(policy.min_version.to_s).to eq("1.0.0")
        expect(policy.enforce_on).to eq(Date.new(2026, 12, 8))
      end
    end

    it "never raises on an env that does" do
      env = Object.new
      def env.[](_name) = raise(KeyError, "boom")
      expect(app.resolve(env)).to have_attributes(min_version: app.min_version, pinned: [], rejected: [])
    end

    it "rejects non-ASCII, invalid or oversized values, never raising" do
      expect(app.resolve(pins(min_version: "0.4.0\u00a0")).rejected).to eq([ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ])
      expect(app.resolve(pins(min_version: "\xff".b)).rejected).to eq([ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ])
      expect(app.resolve(pins(min_version: "1#{'0' * 200}.0.0")).rejected).to eq([ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ])
    end
  end
end
