require "spec_helper"

RSpec.describe StandardFlags::VersionRange do
  def range(text) = described_class.parse(text)

  describe "the neutral syntax" do
    it "takes space-separated comparators with optional || alternatives" do
      parsed = range(">=1.4.0 <2.0.0 || =0.9.5-beta.1")
      expect(parsed.to_s).to eq(">=1.4.0 <2.0.0 || =0.9.5-beta.1")
      expect(%w[1.4.0 1.9.9 0.9.5-beta.1].map { |v| parsed.satisfied_by?(v) }).to all(be(true))
      expect(%w[1.3.9 2.0.0 0.9.5 0.9.5-beta.2].map { |v| parsed.satisfied_by?(v) }).to all(be(false))
    end

    it "allows whitespace after an operator and shorthand versions, and canonicalises them" do
      expect(range("  >= 1.4   < 2 ").to_s).to eq(">=1.4.0 <2.0.0")
      expect(range("> 1 || <= 0.5").to_s).to eq(">1.0.0 || <=0.5.0")
      expect(range(">= 1").inspect).to eq("#<StandardFlags::VersionRange >=1.0.0>")
    end

    it "compares by plain SemVer ordering" do
      expect(range("<2.0.0").satisfied_by?("2.0.0-beta.1")).to be(true)
      expect(range(">=2.0.0").satisfied_by?("2.0.0-beta.1")).to be(false)
      expect(range("=1.4.0").satisfied_by?("1.4.0+381")).to be(true)
      expect(range(">1.0.0-alpha.2").satisfied_by?("1.0.0-alpha.10")).to be(true)
    end

    it "is met by no version that doesn't parse" do
      [ nil, "", "bad", "1.2.3.4" ].each { |v| expect(range(">=0.0.0").satisfied_by?(v)).to be(false) }
    end

    it "refuses malformed ranges" do
      [ ">=1.4.0<2.0.0", "> = 1", ">=1.4.0 <", "1.4.0 || >=2", ">=1 ||", "|| >=1", ">=v1", "~1.4", "^1.4", ">=1.4.0 && <2",
        ">=1.2.3.4", nil, 3, ">=1 " * 400 ].each do |text|
        expect(described_class.neutral(text)).to be_nil, "expected #{text.inspect} not to parse as neutral"
      end
      expect { described_class.parse!("~1.4") }.to raise_error(described_class::Invalid, /"~1.4" is not a version range/)
      expect(described_class.valid?(">=1")).to be(true)
    end
  end

  describe "RubyGems requirements stored before the neutral syntax" do
    {
      ">= 1.4.0" => ">=1.4.0", "~> 1.4" => ">=1.4.0 <2.0.0", "~> 1.4.2" => ">=1.4.2 <1.5.0", "~> 1" => ">=1.0.0 <2.0.0",
      ">= 1.4, < 2" => ">=1.4.0 <2.0.0", "!= 1.5" => "<1.5.0 || >1.5.0", ">= 1.0, != 1.5" => ">=1.0.0 <1.5.0 || >=1.0.0 >1.5.0",
      "1.4.0" => "=1.4.0", "= 1.4" => "=1.4.0", "" => ">=0.0.0", ">= 1.2.3.0" => ">=1.2.3",
      "~> 1.4.0.beta" => ">=1.4.0-beta <1.5.0", "1.4.0.beta.1" => "=1.4.0-beta.1", ">= 1.4.0-rc.1" => ">=1.4.0-rc.1"
    }.each do |legacy, neutral|
      it "reads #{legacy.inspect} as #{neutral}" do
        expect(range(legacy).to_s).to eq(neutral)
        expect(described_class.translate(legacy)).to eq(neutral)
      end
    end

    it "evaluates the common forms exactly as RubyGems does" do
      requirements = [ ">= 1.4.0", "~> 1.4", "~> 1.4.2", ">= 1.4, < 2", "!= 1.5", "> 1.0, <= 3", "1.4.0", "< 2" ]
      versions = %w[0.9.0 1.3.9 1.4.0 1.4.1 1.4.2 1.4.9 1.5.0 1.9.9 2.0.0 3.0.0 3.0.1]
      requirements.product(versions).each do |requirement, client|
        expected = Gem::Requirement.new(*requirement.split(",").map(&:strip)).satisfied_by?(Gem::Version.new(client))
        expect(range(requirement).satisfied_by?(client)).to eq(expected), "#{client} against #{requirement.inspect}"
      end
    end

    it "refuses what neither syntax reads" do
      [ "around 1.4", ">= 1.2.3.4", "~> 1.2.3.4", " , " ].each { |text| expect(range(text)).to be_nil }
      expect(described_class.translate(Array.new(7) { |i| "!= 1.#{i}" }.join(", "))).to be_nil # 128 alternatives
      expect(described_class.translate(nil)).to be_nil
    end
  end

  it "caches parses, answers included, and empties the cache when it fills" do
    stub_const("#{described_class}::CACHE_LIMIT", 2)
    expect(range(">=9.9.1")).to equal(range(">=9.9.1"))
    range(">=9.9.2")
    range(">=9.9.3")
    expect(range(">=9.9.1").to_s).to eq(">=9.9.1")
    expect(range("nope")).to be_nil
  end
end
