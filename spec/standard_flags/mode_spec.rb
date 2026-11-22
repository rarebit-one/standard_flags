require "spec_helper"

RSpec.describe StandardFlags::Mode do
  let(:mode) { described_class.new(:sensor, %i[off sensor on]) }

  it "has a predicate per declared value" do
    expect([ mode.off?, mode.sensor?, mode.on? ]).to eq([ false, true, false ])
    expect(mode).to respond_to(:on?)
  end

  it "raises for an undeclared predicate" do
    expect { mode.enforce? }.to raise_error(NoMethodError)
    expect(mode).not_to respond_to(:enforce?)
  end

  it "orders values" do
    expect([ mode.at_least?(:off), mode.at_least?(:sensor), mode.at_least?("on") ]).to eq([ true, true, false ])
    expect { mode.at_least?(:enforce) }.to raise_error(ArgumentError)
  end

  it "compares with symbols, strings and modes" do
    expect(mode).to eq(:sensor)
    expect(mode).to eq("sensor")
    expect(mode).to eq(described_class.new(:sensor, %i[off sensor on]))
    expect(mode).not_to eq(1)
    expect(mode.hash).to eq(:sensor.hash)
  end

  it "converts and inspects" do
    expect([ mode.to_sym, mode.to_s, mode.inspect ]).to eq([ :sensor, "sensor", "#<StandardFlags::Mode :sensor>" ])
  end

  it "has an unknown mode where every predicate is false" do
    unknown = described_class.unknown
    expect([ unknown.unknown?, unknown.on?, unknown.anything?, unknown.at_least?(:on) ]).to eq([ true, false, false, false ])
  end
end
