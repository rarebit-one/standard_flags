require "spec_helper"

RSpec.describe StandardFlags::Stores do
  it "answers nil without a lookup or an adapter for the client" do
    app = StandardFlags::ClientApp.declare(:android_app, platform: :android)
    expect(described_class.available(app, nil)).to be_nil
    expect(described_class.available(app, { ios_app: ->(_app) { "1.0.0" } })).to be_nil
    expect(described_class.available(app, ->(_app) { "1.0.0" })).to be_nil
    expect(described_class.available(app, { android_app: ->(_app) { StandardFlags::Version.parse("1.0") } }).to_s).to eq("1.0.0")
  end
end
