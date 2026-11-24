require "spec_helper"

RSpec.describe StandardFlags::VersionRange do
  def range(text) = described_class.parse(text)
  def neutral(text) = described_class.neutral(text)

  describe "the neutral syntax" do
    it "takes space-separated comparators with optional || alternatives" do
      parsed = range(">=1.4.0 <2.0.0 || =0.9.5-beta.1")
      expect(parsed.to_s).to eq(">=1.4.0 <2.0.0 || =0.9.5-beta.1")
      expect(%w[1.4.0 1.9.9 0.9.5-beta.1].map { |v| parsed.satisfied_by?(v) }).to all(be(true))
      expect(%w[1.3.9 2.0.0 0.9.5 0.9.5-beta.2].map { |v| parsed.satisfied_by?(v) }).to all(be(false))
    end

    it "allows ASCII spaces and tabs after an operator and around ||, and canonicalises" do
      expect(range("  >= 1.4   < 2 ").to_s).to eq(">=1.4.0 <2.0.0")
      expect(range("> 1 || <= 0.5").to_s).to eq(">1.0.0 || <=0.5.0")
      expect(range(">=1||<0.5").to_s).to eq(">=1.0.0 || <0.5.0")
      expect(range(">=1\t<2").to_s).to eq(">=1.0.0 <2.0.0")
      expect(range(">= 1").inspect).to eq("#<StandardFlags::VersionRange >=1.0.0>")
    end

    it "compares by plain SemVer ordering, with shorthands as exact versions" do
      expect(range("<2.0.0").satisfied_by?("2.0.0-beta.1")).to be(true)
      expect(range(">=2.0.0").satisfied_by?("2.0.0-beta.1")).to be(false)
      expect(range("=1.4.0").satisfied_by?("1.4.0+381")).to be(true)
      expect(range(">1.0.0-alpha.2").satisfied_by?("1.0.0-alpha.10")).to be(true)
      expect([ range(">1.4").satisfied_by?("1.4.1"), range("<=1.4").satisfied_by?("1.4.5") ]).to eq([ true, false ])
    end

    it "is met by no version that doesn't parse, in the neutral form clients use" do
      [ nil, "", "bad", "1.2.3.4", "1.4.0.beta", "\xFF1.0".dup.force_encoding("UTF-8") ].each do |v|
        expect(neutral(">=0.0.0").satisfied_by?(v)).to be(false)
      end
    end

    it "reads versions given as Gem::Version, Float or Symbol through to_s" do
      expect([ Gem::Version.new("1.5.0"), 1.5, :"1.5.0" ].map { |v| range(">=1.4.0 <2.0.0").satisfied_by?(v) }).to all(be(true))
    end

    it "refuses malformed ranges" do
      [ ">=1.4.0<2.0.0", "> = 1", ">=1.4.0 <", "1.4.0 || >=2", ">=1 ||", "|| >=1", ">=v1", "~1.4", "^1.4", ">=1.4.0 && <2",
        ">=1.2.3.4", ">=1.4-beta", ">=1\n<2", ">=1 <2", " >=1", nil, 3, ">=1 " * 400, "~> 1.4", ">= 1.4, < 2" ].each do |text|
        expect(neutral(text)).to be_nil, "expected #{text.inspect} not to parse as neutral"
      end
      expect { described_class.parse!("~1.4") }.to raise_error(described_class::Invalid, /"~1.4" is not a version range/)
      expect(described_class.valid?(">=1")).to be(true)
    end

    it "takes ranges up to 1024 characters" do
      long = Array.new(128) { ">=1.0.0" }.join(" ") # 1023 characters
      expect([ neutral(long).nil?, neutral("#{long} >=1").nil? ]).to eq([ false, true ])
    end
  end

  describe "RubyGems requirements stored by 0.2.x" do
    {
      ">= 1.4.0" => ">=1.4.0", "~> 1.4" => ">=1.4.0 <2.0.0-0", "~> 1.4.2" => ">=1.4.2 <1.5.0-0", "~> 1" => ">=1.0.0 <2.0.0-0",
      ">= 1.4, < 2" => ">=1.4.0 <2.0.0", "!= 1.5" => "<1.5.0 || >1.5.0", ">= 1.0, != 1.5" => ">=1.0.0 <1.5.0 || >=1.0.0 >1.5.0",
      "1.4.0" => "=1.4.0", "= 1.4" => "=1.4.0", "" => ">=0.0.0", ">= 1.2.3.0" => ">=1.2.3",
      "~> 1.4.0.beta" => ">=1.4.0-beta <1.5.0-0", "1.4.0.beta.1" => "=1.4.0-beta.1", ">= 1.4.0-rc.1" => ">=1.4.0-rc.1"
    }.each do |legacy, translation|
      it "reads #{legacy.inspect} as #{translation}" do
        expect(range(legacy).to_s).to eq(translation)
        expect(described_class.translate(legacy)).to eq(translation)
      end
    end

    it "evaluates exactly as RubyGems does, prerelease and non-SemVer client versions included" do
      requirements = [ ">= 1.4.0", "~> 1.4", "~> 1.4.2", "~> 1.4.0", ">= 1.4, < 2", "!= 1.5", "> 1.0, <= 3", "1.4.0", "< 2",
                       "~> 1.4, != 1.5.0", ">= 1.4.0.1", "~> 1.4.2.1", Array.new(7) { |i| "!= 1.#{i}" }.join(", ") ]
      versions = %w[0.9.0 1.3.9 1.4.0-rc.1 1.4.0 1.4.0.1 1.4.1 1.4.2-beta 1.4.2 1.4.2.1 1.4.2.5 1.4.9 1.5.0-beta 1.5.0 1.9.9
                    1.9.9-rc.1 2.0.0-0 2.0.0-beta.1 2.0.0-rc1 2.0.0 3.0.0 3.0.1 1.4.0.beta 01.4.0]
      mismatches = requirements.product(versions).reject do |requirement, client|
        expected = Gem::Requirement.new(*requirement.split(",").map(&:strip)).satisfied_by?(Gem::Version.new(client))
        range(requirement).satisfied_by?(client) == expected
      end
      expect(mismatches).to be_empty
    end

    it "keeps requirements the neutral syntax can't hold, evaluated by RubyGems" do
      untranslatable = range(">= 1.4.0.1")
      expect([ untranslatable.legacy?, untranslatable.alternatives, untranslatable.to_s ]).to eq([ true, nil, ">= 1.4.0.1" ])
      expect(%w[1.4.0.1 1.4.1 2.0.0-beta].map { |v| untranslatable.satisfied_by?(v) }).to all(be(true))
      expect([ untranslatable.satisfied_by?("1.4.0"), untranslatable.satisfied_by?(nil), untranslatable.satisfied_by?("") ]).to all(be(false))
      expect(described_class.translate(">= 1.4.0.1")).to be_nil
      expect(range(Array.new(7) { |i| "!= 1.#{i}" }.join(", ")).to_s).to include("!= 1.6") # 128 alternatives
    end

    it "reads a non-SemVer client version through RubyGems against a range RubyGems can read" do
      expect([ range(">= 1.4.0").satisfied_by?("1.4.0.1"), range(">=1.4.0").satisfied_by?("1.4.0.beta") ]).to eq([ true, false ])
      expect(range(">=1.4.0 <2.0.0").satisfied_by?("1.4.0.1")).to be(false) # neutral only: SemVer only
      expect(range(">= 1.4.0").legacy?).to be(false)
    end

    it "refuses what neither syntax reads" do
      [ "around 1.4", ">= 1, around", nil, "\xFF>= 1".dup.force_encoding("UTF-8") ].each { |text| expect(range(text)).to be_nil }
      expect([ described_class.translate(nil), described_class.translate("around") ]).to eq([ nil, nil ])
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
