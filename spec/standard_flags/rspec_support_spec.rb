require "spec_helper"
require "rspec/core/sandbox"

# Runs host-style example groups in a sandboxed RSpec configuration wired
# the way `require "standard_flags/rspec"` wires a host's, to prove each way
# of setting a flag in a spec is seen by the example and reset afterwards.
RSpec.describe StandardFlags::RSpecSupport do
  before do
    define_flags(&FlagSpecHelpers::SAMPLE_REGISTRY)
  end

  # Runs the group built by the block; returns each example's status and
  # failure messages.
  def run_host_group(&block)
    RSpec::Core::Sandbox.sandboxed do |config|
      StandardFlags::RSpecSupport.install(config)
      group = RSpec.describe("host specs", &block)
      group.run(RSpec::Core::Reporter.new(config))
      results = group.descendants.flat_map(&:examples).map(&:execution_result)
      { statuses: results.map(&:status), failures: results.filter_map { |result| result.exception&.message } }
    end
  end

  let(:two_passed) { { statuses: %i[passed passed], failures: [] } }

  it "keeps an override set in an around hook for the example" do
    result = run_host_group do
      around { |example| with_flag(:new_checkout, true) { example.run } }

      it("reads it") { expect(StandardFlags.on?(:new_checkout)).to be(true) }
      it("reads it in every example") { expect(StandardFlags.on?(:new_checkout)).to be(true) }
    end

    expect(result).to eq(two_passed)
    expect(StandardFlags::Testing.overrides).to be_empty
  end

  it "keeps runtime test rules set in an around hook" do
    result = run_host_group do
      around do |example|
        with_rule(:new_checkout, status: :stopped, stop: true)
        example.run
      end

      it("reads the rule") { expect(StandardFlags.evaluate(:new_checkout).rule_id).to eq("stopped") }
    end

    expect(result).to eq(statuses: %i[passed], failures: [])
    expect(StandardFlags::Testing.runtime_store).to be_nil
  end

  it "applies flags: metadata, which wins over an around override of the same key" do
    result = run_host_group do
      around { |example| with_flag(:new_checkout, true) { with_mode(:strict_gates, :on) { example.run } } }

      it("reads metadata", flags: { new_checkout: false }) do
        expect([ StandardFlags.on?(:new_checkout), StandardFlags.mode(:strict_gates).value ]).to eq([ false, :on ])
      end
    end

    expect(result).to eq(statuses: %i[passed], failures: [])
  end

  it "keeps before hooks and in-example overrides working, and resets between examples" do
    result = run_host_group do
      before { with_flag(:ai_assistant, false) }

      it("sets one") do
        with_flag(:new_checkout, true)
        expect([ StandardFlags.on?(:ai_assistant), StandardFlags.on?(:new_checkout) ]).to eq([ false, true ])
      end

      it("starts clean") { expect([ StandardFlags.on?(:ai_assistant), StandardFlags.on?(:new_checkout) ]).to eq([ false, false ]) }
    end

    expect(result).to eq(two_passed)
  end

  it "fails the example with a clear error instead of discarding overrides set before it" do
    result = run_host_group do
      # rubocop:disable RSpec/BeforeAfterAll -- the leak under test
      before(:context) { StandardFlags::Testing.override(:new_checkout, true) }
      # rubocop:enable RSpec/BeforeAfterAll

      it("would read the code default") { expect(StandardFlags.on?(:new_checkout)).to be(true) }
    end

    expect(result[:statuses]).to eq(%i[failed])
    expect(result[:failures].join).to include("standard_flags test overrides were set before the example started")
    expect(StandardFlags::Testing.overrides).to be_empty
  end
end
