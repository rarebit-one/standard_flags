require "spec_helper"

RSpec.describe StandardFlags::Version do
  def version(text) = described_class.parse(text)

  it "parses SemVer and the MAJOR.MINOR and MAJOR shorthands" do
    expect([ "1.4.0", "1.4", "2", " 3.0.1 ", :"1.2", 7 ].map { |text| version(text)&.to_s })
      .to eq(%w[1.4.0 1.4.0 2.0.0 3.0.1 1.2.0 7.0.0])
    expect(version("1.4.0-beta.2+381")).to have_attributes(major: 1, minor: 4, patch: 0, prerelease: [ "beta", 2 ], build: "381")
  end

  it "refuses what SemVer refuses" do
    [ "v1.4.0", "1.4.0.1", "01.4.0", "1.04", "1.4-beta", "1.4+381", "1.4.0-", "1.4.0-01", "1.4.0-be_ta", "", " ", nil,
      "1" * 200, "1.0.0+#{'b' * 123}", true ].each do |text|
      expect(version(text)).to be_nil, "expected #{text.inspect} not to parse"
    end
    expect { described_class.parse!("nope") }.to raise_error(ArgumentError, /"nope" is not a version/)
  end

  it "reads other values through to_s" do
    expect([ Gem::Version.new("1.4.0"), 1.5, 2 ].map { |value| version(value).to_s }).to eq(%w[1.4.0 1.5.0 2.0.0])
  end

  it "ignores only surrounding ASCII spaces and tabs, and never raises on bytes" do
    expect(version("\t1.4.0 ").to_s).to eq("1.4.0")
    [ "1.4.0\n", "\u00a01.4.0", "1.4.0\0", "\xFF1.4.0".dup.force_encoding("UTF-8"), "1.4.0\xFF".b ].each do |text|
      expect(version(text)).to be_nil, "expected #{text.inspect} not to parse"
    end
    expect(version("1.0.0+#{'b' * 122}")).not_to be_nil # 128 characters
  end

  it "has no size limit on numbers" do
    expect(version("18446744073709551617.0.0") > version("18446744073709551616.9.9")).to be(true)
  end

  it "orders by SemVer precedence" do
    ordered = %w[1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0 1.0.1 1.1.0 2.0.0
                 10.0.0]
    expect(ordered.shuffle(random: Random.new(7)).map { |text| version(text) }.sort.map(&:to_s)).to eq(ordered)
    expect(version("1.0.0-20261125123045") > version("1.0.0-9")).to be(true)
  end

  it "ignores build metadata in comparisons, equality and hashing" do
    expect(version("1.4.0+381")).to eq(version("1.4.0+382"))
    expect(version("1.4.0+381")).to eql(version("1.4"))
    expect({ version("1.4.0+1") => :a }.key?(version("1.4.0"))).to be(true)
    expect([ version("1.4.0") <=> "1.4.0", version("1.4.0").eql?("1.4.0") ]).to eq([ nil, false ])
    expect(version("1.4.0-rc.1").inspect).to eq("#<StandardFlags::Version 1.4.0-rc.1>")
  end

  it "passes a Version through" do
    parsed = version("1.2.3")
    expect(described_class.parse(parsed)).to equal(parsed)
  end
end
