require "spec_helper"

RSpec.describe StandardFlags::Sensor do
  before do
    define_flags do
      mode :strict_gates, owner: "platform", preset: :sensor
      mode :billing_cutover, owner: "billing", preset: :shadow
    end
  end

  def run_sensor(log)
    StandardFlags.sensor(:strict_gates) do |s|
      s.observe { log << :observe; :verdict }
      s.enforce { |observed| log << [ :enforce, observed ]; :held }
    end
  end

  it "runs nothing when off" do
    log = []
    events = capture_events { expect(run_sensor(log)).to be_nil }
    expect([ log, events ]).to eq([ [], [] ])
  end

  it "observes and notifies in sensor mode" do
    log = []
    with_mode(:strict_gates, :sensor) do
      events = capture_events { expect(run_sensor(log)).to eq(:verdict) }
      expect(log).to eq([ :observe ])
      expect(events).to eq([ [ "sensor.standard_flags",
                               { key: :strict_gates, mode: :sensor, observed: :verdict, error_class: nil } ] ])
    end
  end

  it "observes, notifies and enforces when on" do
    log = []
    with_mode(:strict_gates, :on) do
      events = capture_events { expect(run_sensor(log)).to eq(:held) }
      expect(log).to eq([ :observe, [ :enforce, :verdict ] ])
      expect(events.map { |_, payload| payload[:mode] }).to eq([ :on ])
    end
  end

  it "swallows and reports an observe error in sensor mode" do
    with_mode(:strict_gates, :sensor) do
      events = nil
      collector = collect_errors do
        events = capture_events { expect(StandardFlags.sensor(:strict_gates) { |s| s.observe { raise "probe failed" } }).to be_nil }
      end
      expect(collector.reports.map { |r| r[:error].message }).to eq([ "probe failed" ])
      expect(events.first.last).to include(observed: nil, error_class: "RuntimeError")
    end
  end

  it "lets an observe error propagate when on" do
    with_mode(:strict_gates, :on) do
      expect { StandardFlags.sensor(:strict_gates) { |s| s.observe { raise "probe failed" } } }.to raise_error("probe failed")
    end
  end

  it "returns the observation when on without an enforce block" do
    with_mode(:strict_gates, :on) do
      expect(StandardFlags.sensor(:strict_gates) { |s| s.observe { 42 } }).to eq(42)
    end
  end

  it "refuses a mode without the sensor preset" do
    expect { StandardFlags.sensor(:billing_cutover) { |s| s.observe { 1 } } }.to raise_error(StandardFlags::TypeMismatch, /preset: :sensor/)

    StandardFlags.config.strict = false
    with_mode(:billing_cutover, :enforce) do
      expect(StandardFlags.sensor(:billing_cutover) { |s| s.observe { 1 } }).to be_nil
    end
  end

  it "needs a block" do
    expect { StandardFlags.sensor(:strict_gates) }.to raise_error(ArgumentError)
  end
end
