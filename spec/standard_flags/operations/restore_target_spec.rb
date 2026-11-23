require "spec_helper"

# Restore's one write per target. Restore's own specs cover the plans it is
# given; these cover what the write refuses and how it creates a rule again.
RSpec.describe StandardFlags::Operations::RestoreTarget, registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
  end

  def restore(target, **args)
    described_class.call(target, actor: StandardFlags::Actor.system("restore"), reason: "restore to T: x", **args)
  end

  def refusal(target, **args)
    result = restore(target, **args)
    [ result.code, result.errors.first ]
  end

  it "is named restore in reports" do
    expect(described_class.operation_name).to eq("restore")
  end

  it "creates a rule again with the salt and hash version it had" do
    result = restore(:new_checkout, attributes: { fallthrough_value: "on" }, bucketing: { salt: "then", hash_version: 1 })
    expect(result).to be_success
    expect(store.rule(:new_checkout)).to have_attributes(salt: "then", hash_version: 1, fallthrough_value: "on")
  end

  it "sets full_since as Ramp does" do
    restore(:new_checkout, attributes: { percentage_bps: 10_000 })
    full_since = store.rule(:new_checkout).full_since
    expect(full_since).to be_a(Time)
    restore(:new_checkout, attributes: { percentage_bps: 10_000, fallthrough_value: "off" })
    expect(store.rule(:new_checkout).full_since).to eq(full_since)
    restore(:new_checkout, attributes: { percentage_bps: 500 })
    expect(store.rule(:new_checkout).full_since).to be_nil
  end

  it "refuses what no operation would store" do
    expect(refusal(:new_checkout, attributes: { salt: "x" })).to eq([ :invalid, "unknown rule attribute(s): salt" ])
    expect(refusal(:new_checkout, attributes: { status: "gone" })).to eq([ :invalid, "status \"gone\" is not one of draft/paused/running/stopped" ])
    expect(refusal(:new_checkout, attributes: { conditions: [] })).to eq([ :invalid, "conditions must be a Hash" ])
    StandardFlags.config.max_cohorts_per_rule = 1
    two = [ { "cohort" => "a", "value" => "on" }, { "cohort" => "b", "value" => "on" } ]
    expect(refusal(:new_checkout, attributes: { cohorts: two })).to eq([ :limit_exceeded, ":new_checkout would have 2 cohorts; the limit is 1" ])
  end

  it "never un-stops a rule, and checks a rule that won't be running" do
    op!(OperationHelpers::Ops::Stop, :new_checkout, serve: true)
    expect(refusal(:new_checkout, attributes: { status: "paused" })).to eq([ :invalid, ":new_checkout is stopped; operations can't un-stop a rule" ])
    expect(refusal(:home_hero, attributes: { status: "paused", percentage_bps: 100 }).first).to eq(:invalid)
  end

  it "refuses member groups of another unit, and blank or unstored keys" do
    group = { unit: :phone, keys: %w[+6591234567], value: "on" }
    expect(refusal(:new_checkout, add: [ group ])).to eq([ :invalid, "unit: :phone does not match :account" ])
    blank = { unit: :account, keys: [ " " ], value: "on" }
    expect(refusal(:new_checkout, add: [ blank ])).to eq([ :invalid, "1 of the keys is blank" ])
    expect(refusal(:new_checkout, add: [ blank.merge(keys: [ 7 ]) ])).to eq([ :invalid, "normalized keys must be Strings" ])
  end

  it "refuses members for an archived, missing or undeclared cohort" do
    store.put_cohort(:alumni, unit: :account, archived_at: Time.utc(2026, 1, 1))
    expect(refusal("cohort:alumni", add: [ { unit: :account, keys: %w[a1] } ])).to eq([ :invalid, "cohort \"alumni\" is archived" ])
    expect(refusal("cohort:ghost", remove: [ { unit: :account, keys: %w[a1] } ])).to eq([ :invalid, "cohort \"ghost\" does not exist" ])
    store.put_cohort(:odd, unit: :device)
    expect(refusal("cohort:odd", remove: [ { unit: :device, keys: %w[d1] } ])).to eq([ :invalid, "cohort \"odd\" holds :device, which is not declared" ])
  end

  it "reports an unexpected error by its class only, since it handles unit keys" do
    reports = []
    StandardFlags.config.error_reporter = ->(error, context) { reports << [ error.message, context ] }
    allow(store).to receive(:tx_remove_members).and_raise(ArgumentError, "bad key +6591234567")
    result = restore(:new_checkout, remove: [ { unit: :account, keys: %w[+6591234567] } ])
    expect([ result.code, reports ]).to eq([ :error, [ [ "restore failed: ArgumentError", { operation: "restore", flag: "new_checkout" } ] ] ])
  end
end
