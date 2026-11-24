require "spec_helper"

# Runs spec/fixtures/conformance/versions/version_ranges.json: a version and
# a range in, matched or not out. Clients (Kotlin, TypeScript) run the same
# file, so every side agrees on what a version range means. Only the neutral
# syntax is portable, so this reads ranges with VersionRange.neutral.
RSpec.describe "version range conformance fixtures" do
  fixture = ConformanceRegistry.load(File.expand_path("fixtures/conformance/versions/version_ranges.json", __dir__))

  fixture.fetch("cases").each do |example|
    it "#{example['version'].inspect} against #{example['range'].inspect} is #{example['matched'] ? 'matched' : 'not matched'}" do
      range = StandardFlags::VersionRange.neutral(example.fetch("range"))
      expect(range).not_to be_nil
      expect(range.satisfied_by?(example["version"])).to eq(example.fetch("matched"))
    end
  end

  fixture.fetch("invalid_ranges").each do |text|
    it "refuses #{text.inspect}" do
      expect(StandardFlags::VersionRange.neutral(text)).to be_nil
    end
  end
end
