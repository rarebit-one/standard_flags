require "spec_helper"

RSpec.describe StandardFlags::Diagnostics, ".report" do
  before do
    StandardFlags.define do
      flag :new_checkout, owner: "payments", remove_by: "2099-01-01", final: true
      client :android_app, platform: :android, min_version: "0.4.0", since: "2026-12-01", recommended: "0.5.0",
                           available: "0.5.0", store_url: "https://example.com/store/android"
      client :ios_app, platform: :ios, group: :kiosk, grace: 14
    end
  end

  it "lists each client with the values in force" do
    report = described_class.report
    expect(report[:clients]).to eq([
      { name: :android_app, platform: "android", group: nil, min_version: "0.4.0", since: "2026-12-01", enforce_on: "2026-12-08",
        grace_days: 7, recommended: "0.5.0", available: "0.5.0", store_url: "https://example.com/store/android",
        store_lookup: false, pinned: [], rejected: [] },
      { name: :ios_app, platform: "ios", group: :kiosk, min_version: nil, since: nil, enforce_on: nil, grace_days: 14,
        recommended: nil, available: nil, store_url: nil, store_lookup: false, pinned: [], rejected: [] }
    ])
    expect(report[:status]).to eq(:ok)
  end

  it "lists break-glass pins without warning, as flags' pins are, and warns on ignored ones by name only" do
    StandardFlags.config.env_source = { "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" => "0.3.5",
                                        "STANDARD_FLAGS_CLIENT_ANDROID_APP_RECOMMENDED" => "soon",
                                        "STANDARD_FLAGS_CLIENT_IOS_APP_AVAILABLE" => "3.0.0",
                                        "STANDARD_FLAGS_CLIENT_GONE_APP_MIN_VERSION" => "1.0.0" }
    report = described_class.report
    expect(report[:clients].first).to include(min_version: "0.3.5", recommended: "0.5.0",
                                              pinned: [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ],
                                              rejected: [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_RECOMMENDED" ])
    expect(report[:clients].last[:pinned]).to eq([ "STANDARD_FLAGS_CLIENT_IOS_APP_AVAILABLE" ])
    expect(report[:unknown_env_vars]).to eq([ "STANDARD_FLAGS_CLIENT_GONE_APP_MIN_VERSION" ])
    warnings = described_class.warnings(report)
    expect(warnings.grep(/CLIENT_(ANDROID|IOS)_APP/)).to eq(
      [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_RECOMMENDED for client :android_app was ignored (invalid, or a raised minimum without _SINCE)" ]
    )
    expect(warnings.join).not_to include("0.3.5", "soon")
  end

  it "keeps the health status ok when a valid break-glass pin is in force" do
    StandardFlags.config.env_source = { "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" => "0.3.5",
                                        "STANDARD_FLAGS_CLIENT_IOS_APP_AVAILABLE" => "3.0.0" }
    report = described_class.report
    expect([ report[:status], described_class.warnings(report) ]).to eq([ :ok, [] ])
  end

  it "warns on a raised minimum pinned without _SINCE, and takes it with one" do
    StandardFlags.config.env_source = { "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" => "0.4.5" }
    report = described_class.report
    expect(report[:clients].first).to include(min_version: "0.4.0", pinned: [], rejected: [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ])
    expect(report[:status]).to eq(:warn)
    StandardFlags.config.env_source["STANDARD_FLAGS_CLIENT_ANDROID_APP_SINCE"] = "2026-12-09"
    expect(described_class.report[:clients].first).to include(min_version: "0.4.5", enforce_on: "2026-12-16")
  end

  it "says which clients have a store lookup, without asking it" do
    lookup = ->(_app) { raise "a health check must never wait on a store" }
    StandardFlags.define do
      client :android_app, platform: :android
      client :ios_app, platform: :ios, store_lookup: lookup
    end
    expect(described_class.report[:clients].map { |client| client[:store_lookup] }).to eq([ false, true ])
  end
end
