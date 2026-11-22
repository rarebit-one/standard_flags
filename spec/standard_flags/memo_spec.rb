require "spec_helper"

RSpec.describe StandardFlags::Memo do
  before do
    define_flags { kill_switch :ai_assistant, owner: "assistant" }
  end

  it "is opened and closed by the host app's executor" do
    active = nil
    Rails.application.executor.wrap { active = described_class.active? }
    expect([ active, described_class.active? ]).to eq([ true, false ])
  end

  it "memoises within one unit of work and re-reads ENV in the next" do
    Rails.application.executor.wrap do
      expect(described_class).to be_active
      expect(StandardFlags.on?(:ai_assistant)).to be(true)
      set_env("STANDARD_FLAGS_AI_ASSISTANT" => "off")
      expect(StandardFlags.on?(:ai_assistant)).to be(true)
    end

    expect(described_class).not_to be_active
    Rails.application.executor.wrap { expect(StandardFlags.on?(:ai_assistant)).to be(false) }
  end

  it "covers jobs, which run inside the executor" do
    job = Class.new(ActiveJob::Base) do
      def self.name = "MemoProbeJob"

      def perform
        StandardFlags::Memo.active?
      end
    end

    result = nil
    Rails.application.executor.wrap { result = job.perform_now }
    expect(result).to be(true)
  end

  it "keys entries by context" do
    calls = 0
    allow(StandardFlags::Resolvers::CHAIN.last).to receive(:call).and_wrap_original do |original, request|
      calls += 1
      original.call(request)
    end

    Rails.application.executor.wrap do
      2.times { StandardFlags.on?(:ai_assistant, for: "acct_1") }
      StandardFlags.on?(:ai_assistant, for: "acct_2")
    end
    expect(calls).to eq(2)
  end

  it "is cleared when an override changes mid-unit" do
    Rails.application.executor.wrap do
      expect(StandardFlags.on?(:ai_assistant)).to be(true)
      with_flag(:ai_assistant, false) { expect(StandardFlags.on?(:ai_assistant)).to be(false) }
      expect(StandardFlags.on?(:ai_assistant)).to be(true)
    end
  end

  it "does nothing outside a unit of work" do
    expect(described_class.fetch(:key) { 1 }).to eq(1)
    expect(described_class.fetch(:key) { 2 }).to eq(2)
    expect(described_class.clear!).to be_nil
  end
end
