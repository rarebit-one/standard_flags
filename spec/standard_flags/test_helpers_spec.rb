require "spec_helper"

RSpec.describe StandardFlags::TestHelpers do
  before do
    define_flags(&FlagSpecHelpers::SAMPLE_REGISTRY)
  end

  it "overrides a flag for a block, then restores it" do
    with_flag(:new_checkout, true) { expect(StandardFlags.on?(:new_checkout)).to be(true) }
    expect(StandardFlags.on?(:new_checkout)).to be(false)
  end

  it "overrides for the rest of the example without a block" do
    with_flag(:ai_assistant, false)
    expect(StandardFlags.on?(:ai_assistant)).to be(false)
  end

  it "overrides modes and variants" do
    with_mode(:strict_gates, "on") { expect(StandardFlags.mode(:strict_gates)).to be_on }
    with_variant(:home_hero, :savings) { expect(StandardFlags.variant(:home_hero)).to eq("savings") }
  end

  it "nests and restores in order" do
    with_flag(:new_checkout, true) do
      with_flag(:new_checkout, false) { expect(StandardFlags.on?(:new_checkout)).to be(false) }
      expect(StandardFlags.on?(:new_checkout)).to be(true)
    end
  end

  it "applies flags: metadata", flags: { new_checkout: true, strict_gates: :sensor },
                                registry: FlagSpecHelpers::SAMPLE_REGISTRY do
    expect([ StandardFlags.on?(:new_checkout), StandardFlags.mode(:strict_gates).sensor? ]).to eq([ true, true ])
  end

  it "raises on unknown keys, wrong kinds and undeclared values" do
    expect { with_flag(:nope, true) }.to raise_error(StandardFlags::UnknownFlag)
    expect { with_flag(:strict_gates, true) }.to raise_error(StandardFlags::TypeMismatch, /is a mode/)
    expect { with_mode(:strict_gates, :enforce) }.to raise_error(ArgumentError, /not one of/)
    expect { with_flag(:new_checkout, "yes") }.to raise_error(ArgumentError)
    expect { with_variant(:home_hero, "treatment") }.to raise_error(ArgumentError)
  end

  it "reads unknown keys strictly" do
    expect(StandardFlags.config).to be_strict
  end

  describe "automatic reset" do
    # Example order is random, so each half asserts the state it needs.
    it "starts every example without overrides" do
      expect(StandardFlags::Testing.overrides).to be_empty
      with_flag(:new_checkout, true)
    end

    it "starts every example without overrides, whichever runs first" do
      expect(StandardFlags::Testing.overrides).to be_empty
      with_flag(:ai_assistant, false)
    end
  end
end
