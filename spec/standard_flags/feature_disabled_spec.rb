require "spec_helper"

RSpec.describe StandardFlags::FeatureDisabled do
  before do
    StandardFlags.define do
      flag :new_checkout, owner: "payments", remove_by: "2027-01-01", final: true, expose: { mobile: :checkoutV2, web: :checkout }
      flag :internal_only, owner: "payments", remove_by: "2027-01-01", final: true
    end
  end

  it "names the default audience's wire name, else the first, else the key" do
    expect(described_class.new(:new_checkout)).to have_attributes(key: :new_checkout, feature: "checkout", status: 403,
                                                                   message: "checkout is disabled")
    StandardFlags.config.default_audience = :device
    expect(described_class.new("new_checkout").feature).to eq("checkoutV2")
    expect(described_class.new(:internal_only).feature).to eq("internal_only")
    expect(described_class.new(:undeclared, "custom", status: 404, feature: "x")).to have_attributes(feature: "x", message: "custom", status: 404)
    expect(described_class.ancestors).to include(StandardFlags::Error)
  end

  it "is raised by StandardFlags.require! when the flag is off" do
    expect { StandardFlags.require!(:new_checkout) }.to raise_error(described_class, "checkout is disabled")
    with_flag(:new_checkout, true) { expect(StandardFlags.require!(:new_checkout)).to be(true) }
  end
end
