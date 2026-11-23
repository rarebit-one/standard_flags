require "spec_helper"

RSpec.describe StandardFlags::Reporting do
  describe ".once" do
    it "runs the block the first time a token is seen" do
      runs = []
      2.times { described_class.once(:unknown, :nope) { runs << :nope } }
      expect(runs).to eq([ :nope ])
    end

    it "is bounded at 1,000 tokens by default" do
      expect(described_class::LIMIT).to eq(1_000)
    end

    it "stops recording new tokens at the cap and notifies once" do
      stub_const("StandardFlags::Reporting::LIMIT", 2)
      runs = []
      events = capture_events do
        %i[a b c d].each { |token| described_class.once(:unknown, token) { runs << token } }
      end

      expect(runs).to eq(%i[a b])
      expect(events).to eq([ [ "report_registry_full.standard_flags", { limit: 2 } ] ])
      expect(described_class.once(:unknown, :a) { runs << :again }).to be(false)
      expect(runs).to eq(%i[a b])
    end

    it "logs a full registry as a warning" do
      expect(StandardFlags::Notifiers::Logger.new(Logger.new(nil)).call("report_registry_full.standard_flags", { limit: 2 }))
        .to eq("report registry full (2 entries); new warnings are no longer reported in this process")
    end

    it "starts recording again after reset!" do
      stub_const("StandardFlags::Reporting::LIMIT", 1)
      described_class.once(:unknown, :a) { }
      described_class.reset!
      runs = []
      events = capture_events { described_class.once(:unknown, :b) { runs << :b } }
      expect([ runs, events ]).to eq([ %i[b], [] ])
    end
  end
end
