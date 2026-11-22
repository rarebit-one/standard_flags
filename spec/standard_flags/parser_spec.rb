require "spec_helper"

RSpec.describe StandardFlags::Parser do
  let(:boolean) { StandardFlags::Definition.new(:kill_switch, :ai_assistant, owner: "x") }
  let(:mode) { StandardFlags::Definition.new(:mode, :strict_gates, owner: "x", preset: :sensor) }
  let(:experiment) { StandardFlags::Definition.new(:experiment, :home_hero, owner: "x", variants: %w[control Savings]) }

  it "accepts the boolean words, trimmed and case-insensitive" do
    expect(%w[on true 1 yes ON True\  \ Yes].map { |raw| described_class.parse(boolean, raw) }).to all(be(true))
    expect(%w[off false 0 no OFF False\  \ No].map { |raw| described_class.parse(boolean, raw) }).to all(be(false))
  end

  it "rejects anything else for booleans" do
    %w[enabled disabled 2 y n t f].each do |raw|
      expect(described_class.parse(boolean, raw)).to equal(described_class::INVALID)
    end
  end

  it "accepts declared mode values only" do
    expect(described_class.parse(mode, " SENSOR ")).to eq(:sensor)
    expect(described_class.parse(mode, "true")).to equal(described_class::INVALID)
  end

  it "returns the declared spelling of an experiment variant" do
    expect(described_class.parse(experiment, "savings")).to eq("Savings")
    expect(described_class.parse(experiment, "treatment")).to equal(described_class::INVALID)
  end

  it "treats nil and whitespace as blank" do
    expect([ nil, "", "  " ].map { |raw| described_class.blank?(raw) }).to all(be(true))
    expect(described_class.blank?("0")).to be(false)
  end

  it "exposes a standalone boolean parser" do
    expect([ described_class.boolean("yes"), described_class.boolean("no") ]).to eq([ true, false ])
    expect(described_class::INVALID.inspect).to eq("StandardFlags::Parser::INVALID")
  end
end
