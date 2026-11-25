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

  it "reports break-glass pins and ignored ones as warnings, by name only" do
    StandardFlags.config.env_source = { "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" => "0.4.5",
                                        "STANDARD_FLAGS_CLIENT_ANDROID_APP_RECOMMENDED" => "soon",
                                        "STANDARD_FLAGS_CLIENT_IOS_APP_AVAILABLE" => "3.0.0",
                                        "STANDARD_FLAGS_CLIENT_GONE_APP_MIN_VERSION" => "1.0.0" }
    report = described_class.report
    expect(report[:clients].first).to include(min_version: "0.4.5", recommended: "0.5.0",
                                              pinned: [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION" ],
                                              rejected: [ "STANDARD_FLAGS_CLIENT_ANDROID_APP_RECOMMENDED" ])
    expect(report[:unknown_env_vars]).to eq([ "STANDARD_FLAGS_CLIENT_GONE_APP_MIN_VERSION" ])
    warnings = described_class.warnings(report)
    expect(warnings).to include(
      "STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION pins client :android_app (break-glass; the code's value is overridden)",
      "STANDARD_FLAGS_CLIENT_ANDROID_APP_RECOMMENDED for client :android_app is not a valid value (ignored)",
      "STANDARD_FLAGS_CLIENT_IOS_APP_AVAILABLE pins client :ios_app (break-glass; the code's value is overridden)"
    )
    expect(warnings.join).not_to include("0.4.5", "soon")
    expect(report[:status]).to eq(:warn)
  end

  it "says which clients have a store lookup, without asking it" do
    lookup = ->(_app) { raise "a health check must never wait on a store" }
    StandardFlags.config.client_store_lookup = lookup
    expect(described_class.report[:clients].map { |client| client[:store_lookup] }).to eq([ false, true ])
    StandardFlags.config.client_store_lookup = { "android_app" => lookup }
    expect(described_class.report[:clients].map { |client| client[:store_lookup] }).to eq([ true, false ])
  end
end
