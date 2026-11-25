require "spec_helper"

# Runs conformance/versions/legacy_ranges.json, the server-only
# contract for version ranges stored by 0.2.x in RubyGems syntax: each case
# must agree with Gem::Requirement, and with what VersionRange reads.
RSpec.describe "legacy version range fixtures" do
  fixture = ConformanceRegistry.load(ConformanceRegistry.path("versions/legacy_ranges.json"))

  it "is server-only" do
    expect(fixture.fetch("scope")).to eq("server")
  end

  fixture.fetch("translations").each do |example|
    it "stores #{example['range'].inspect} as #{example['neutral'].inspect}" do
      expect(StandardFlags::VersionRange.translate(example.fetch("range"))).to eq(example.fetch("neutral"))
    end
  end

  fixture.fetch("cases").each do |example|
    it "#{example['version'].inspect} against #{example['range'].inspect[0, 60]} is #{example['matched'] ? 'matched' : 'not matched'}" do
      requirement = Gem::Requirement.new(*example.fetch("range").split(",").map(&:strip))
      expect(requirement.satisfied_by?(Gem::Version.new(example.fetch("version")))).to eq(example.fetch("matched"))
      expect(StandardFlags::VersionRange.parse(example.fetch("range")).satisfied_by?(example.fetch("version")))
        .to eq(example.fetch("matched"))
    end
  end
end
