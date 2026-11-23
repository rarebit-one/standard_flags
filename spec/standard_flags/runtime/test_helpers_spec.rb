require "spec_helper"

RSpec.describe "runtime test helpers", registry: RuntimeHelpers::REGISTRY do
  it "turns runtime rules on for the example only" do
    expect(StandardFlags::Runtime).not_to be_enabled
    with_rule(:new_checkout, fallthrough: true)
    expect(StandardFlags::Runtime).to be_enabled
    expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(true)
  end

  it "has reset between examples" do
    expect(StandardFlags::Testing.runtime_store).to be_nil
    expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(false)
  end

  it "beats the app's own runtime store" do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = StandardFlags::Runtime::MemoryStore.new
    with_rule(:strict_gates, fallthrough: :on)
    expect(StandardFlags.mode(:strict_gates, for: for_account(1))).to be_on
    expect(StandardFlags.config.runtime_store.reads).to be_empty
  end

  it "creates a running rule for members and sees changes at once" do
    with_members(:new_checkout, [ account(1), "2" ])
    expect(StandardFlags.on?(:new_checkout, for: for_account(2))).to be(true)
    with_members(:new_checkout, account(2), value: false)
    expect(StandardFlags.evaluate(:new_checkout, for: for_account(2)).rule_id).to eq("deny")
    expect(StandardFlags::Testing.runtime_store.rule(:new_checkout)).to have_attributes(status: "running", member_count: 2)
  end

  it "lets with_flag beat with_rule" do
    with_rule(:new_checkout, fallthrough: true)
    with_flag(:new_checkout, false)
    expect(StandardFlags.evaluate(:new_checkout, for: for_account(1)).reason).to eq("STATIC")
  end

  it "rejects values and keys the registry doesn't allow" do
    expect { with_rule(:new_checkout, fallthrough: :sensor) }.to raise_error(ArgumentError, /not one of \[true, false\]/)
    expect { with_rule(:home_hero, variants: { "bogus" => 10_000 }) }.to raise_error(ArgumentError)
    expect { with_rule(:nope) }.to raise_error(StandardFlags::UnknownFlag)
  end

  it "rejects units the registry doesn't allow" do
    expect { with_members(:global_banner, "1") }.to raise_error(ArgumentError, "flag :global_banner has no unit: to target")
    expect { with_members(:new_checkout, " ") }.to raise_error(ArgumentError, /has no key for unit :account/)
    expect { with_cohort(:staff, unit: :team) }.to raise_error(ArgumentError, "unknown unit :team")
  end
end
