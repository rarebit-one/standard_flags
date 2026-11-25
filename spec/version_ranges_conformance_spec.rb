require "spec_helper"

# Runs conformance/versions/version_ranges.json: a version and
# a range in, matched or not out. Clients (Kotlin, TypeScript) run the same
# file, so every side agrees on what a version range means. Only the neutral
# syntax is portable, so this reads ranges with VersionRange.neutral.
RSpec.describe "version range conformance fixtures" do
  fixture = ConformanceRegistry.load(ConformanceRegistry.path("versions/version_ranges.json"))

  fixture.fetch("cases").each do |example|
    it "#{example['version'].inspect} against #{example['range'].inspect} is #{example['matched'] ? 'matched' : 'not matched'}" do
      range = StandardFlags::VersionRange.neutral(example.fetch("range"))
      expect(range).not_to be_nil
      expect(range.satisfied_by?(example["version"])).to eq(example.fetch("matched"))
    end

    # The server's read path (VersionRange.parse, as runtime rules use it)
    # agrees with clients except where a case says otherwise.
    server = example.fetch("server_matched", example.fetch("matched"))
    it "#{example['version'].inspect} against #{example['range'].inspect} is #{server ? 'matched' : 'not matched'} on the server" do
      expect(StandardFlags::VersionRange.parse(example.fetch("range")).satisfied_by?(example["version"])).to eq(server)
    end
  end

  it "marks every case where the server and clients differ" do
    marked = fixture.fetch("cases").select { |example| example.key?("server_matched") }
    expect(marked.map { |example| example["server_matched"] == example["matched"] }).to all(be(false))
    expect(marked.size).to eq(5)
  end

  fixture.fetch("invalid_ranges").each do |text|
    it "refuses #{text.inspect[0, 80]}" do
      expect(StandardFlags::VersionRange.neutral(text)).to be_nil
    end
  end

  fixture.fetch("build_cases").each do |example|
    it "build #{example['build'].inspect} against #{example['range'].inspect} is #{example['matched'] ? 'matched' : 'not matched'}" do
      range = StandardFlags::BuildRange.parse(example.fetch("range"))
      expect(range).not_to be_nil
      expect(range.satisfied_by?(example["build"])).to eq(example.fetch("matched"))
    end
  end

  fixture.fetch("invalid_build_ranges").each do |text|
    it "refuses the build range #{text.inspect}" do
      expect(StandardFlags::BuildRange.parse(text)).to be_nil
    end
  end
end
