require "spec_helper"

RSpec.describe StandardFlags::ClientUpgradeRequired do
  it "carries the status it was raised for, or keywords" do
    StandardFlags.define do
      client :android_app, platform: :android, min_version: "0.4.0", since: "2026-11-01", store_url: "https://example.com/s"
    end
    result = StandardFlags::ClientStatus.for({ platform: "android", version: "0.3.0" })
    error = described_class.new(result)
    expect(error).to have_attributes(client: :android_app, platform: "android", version: "0.3.0", min_version: "0.4.0",
                                     store_url: "https://example.com/s", status: 426,
                                     message: "client android 0.3.0 must upgrade to 0.4.0")
    expect(described_class.new(min_version: "1.0.0").message).to eq("client must upgrade to 1.0.0")
    expect(described_class.new(nil, "custom").message).to eq("custom")
    expect(described_class.ancestors).to include(StandardFlags::Error)
  end
end
