require "spec_helper"

RSpec.describe StandardFlags::Stores do
  it "answers nil for a client without a lookup, and the lookup's version otherwise" do
    expect(described_class.available(StandardFlags::ClientApp.declare(:android_app, platform: :android))).to be_nil
    app = StandardFlags::ClientApp.declare(:ios_app, platform: :ios, store_lookup: ->(_app) { StandardFlags::Version.parse("1.0") })
    expect(described_class.available(app).to_s).to eq("1.0.0")
    expect(app).to be_store_lookup
  end

  it "refuses a store_lookup that can't be called" do
    expect { StandardFlags.define { client :ios_app, platform: :ios, store_lookup: "com.example.app" } }
      .to raise_error(StandardFlags::DefinitionError, /store_lookup: must respond to call\(client_app\)/)
  end

  it "has no global lookup any more" do
    expect(StandardFlags.config).not_to respond_to(:client_store_lookup=)
  end
end
