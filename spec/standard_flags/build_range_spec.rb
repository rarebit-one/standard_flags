require "spec_helper"

RSpec.describe StandardFlags::BuildRange do
  def range(text) = described_class.parse(text)

  it "takes the comparator syntax over non-negative integers" do
    parsed = range(">=120 <200 || =7")
    expect(parsed.to_s).to eq(">=120 <200 || =7")
    expect([ 120, "199", 7, " 150 " ].map { |b| parsed.satisfied_by?(b) }).to all(be(true))
    expect([ 119, 200, "8", nil, "-1", -1, "1.2", 1.5 ].map { |b| parsed.satisfied_by?(b) }).to all(be(false))
  end

  it "refuses versions, signs and RubyGems forms" do
    [ ">= 1.4.0", ">=-1", "~> 120", ">= 120, < 200", "", "120" ].each { |text| expect(range(text)).to be_nil }
    expect(described_class.translate(">= 120, < 200")).to be_nil
    expect { described_class.parse!("lots") }.to raise_error(StandardFlags::VersionRange::Invalid, /"lots" is not a build range/)
  end

  it "reads build numbers from integers and digit strings" do
    expect([ 0, "381", " 007 ", -1, "-1", "3a", nil, :"12" ].map { |value| described_class.number(value) })
      .to eq([ 0, 381, 7, nil, nil, nil, nil, 12 ])
  end
end
