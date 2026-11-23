require "spec_helper"

# What evaluation costs in store reads, against the in-memory store. The
# :db specs assert the same paths in SQL queries.
RSpec.describe "runtime rule read cost", registry: RuntimeHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:time) { [ 0.0 ] }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
    StandardFlags::Runtime.clock = -> { time.first }
    # Reads only: the end-of-work last_evaluated_at write is covered in
    # evaluation_tracking_spec.
    StandardFlags.config.track_evaluations = false
  end

  def unit_of_work(&)
    Rails.application.executor.wrap(&)
  end

  def reads_during
    before = store.reads.dup
    yield
    store.reads.to_h { |name, count| [ name, count - before.fetch(name, 0) ] }.reject { |_, count| count.zero? }
  end

  it "reads nothing per evaluation once rules are cached and no rule has members" do
    store.put_rule(:new_checkout, status: :running, percentage_bps: 5_000)
    store.put_rule(:strict_gates, status: :running, fallthrough_value: "sensor")
    StandardFlags.evaluate(:new_checkout, for: for_account(0))

    reads = reads_during do
      unit_of_work { (1..20).each { |id| StandardFlags.evaluate(:new_checkout, for: for_account(id)) } }
      unit_of_work { StandardFlags.snapshot(for: for_account(1)) }
    end
    expect(reads).to eq({})
  end

  it "reads memberships once per unit per unit of work" do
    store.put_rule(:new_checkout, status: :running)
    store.put_rule(:strict_gates, status: :running)
    store.add_member(rule: :new_checkout, unit: :account, unit_key: "1", value: true)
    store.put_cohort(:staff, unit: :account)
    store.add_member(cohort: :staff, unit: :account, unit_key: "1", value: true)
    store.put_rule(:strict_gates, cohorts: { staff: :on })
    StandardFlags.evaluate(:global_banner)

    reads = reads_during do
      unit_of_work do
        3.times { %i[new_checkout strict_gates].each { |key| StandardFlags.evaluate(key, for: for_account(1)) } }
        StandardFlags.evaluate(:new_checkout, for: for_account(2))
      end
    end
    expect(reads).to eq(memberships: 2)
  end

  it "skips the membership read for a flag whose rule has no members" do
    store.put_rule(:new_checkout, status: :running)
    store.add_member(rule: :new_checkout, unit: :account, unit_key: "1", value: true)
    store.put_rule(:strict_gates, status: :running, percentage_bps: 10_000, rollout_value: "on")
    StandardFlags.evaluate(:global_banner)

    expect(reads_during { unit_of_work { StandardFlags.evaluate(:strict_gates, for: for_account(1)) } }).to eq({})
  end

  it "preloads a list of units in one read" do
    store.put_rule(:new_checkout, status: :running)
    store.add_member(rule: :new_checkout, unit: :account, unit_key: "3", value: true)
    accounts = (1..10).map { |id| account(id) }
    StandardFlags.evaluate(:global_banner)

    values = nil
    reads = reads_during do
      unit_of_work do
        expect(StandardFlags.preload(:account, accounts)).to eq(10)
        expect(StandardFlags.preload(:account, accounts)).to eq(0)
        values = accounts.map { |a| StandardFlags.on?(:new_checkout, for: { account: a }) }
      end
    end
    expect(reads).to eq(memberships: 1)
    expect(values).to eq([ false, false, true ] + [ false ] * 7)
  end

  it "doesn't preload when nothing could match, outside a unit of work, or with runtime rules off" do
    store.put_rule(:new_checkout, status: :running)
    unit_of_work { expect(StandardFlags.preload(:account, [ account(1) ])).to eq(0) }
    store.add_member(rule: :new_checkout, unit: :account, unit_key: "1", value: true)
    expect(StandardFlags.preload(:account, [ account(1) ])).to eq(0)
    StandardFlags.config.runtime_rules = false
    unit_of_work { expect(StandardFlags.preload(:account, [ account(1) ])).to eq(0) }
    expect(store.reads[:memberships]).to eq(0)
  end

  it "refuses an undeclared unit" do
    unit_of_work { expect { StandardFlags.preload(:team, [ 1 ]) }.to raise_error(ArgumentError, /unknown unit :team/) }
  end

  it "checks the revision once per interval" do
    StandardFlags.config.track_evaluations = false # its write has its own specs
    store.put_rule(:new_checkout, status: :running, fallthrough_value: true)
    reads = reads_during do
      10.times do
        unit_of_work { StandardFlags.evaluate(:new_checkout, for: for_account(1)) }
        time[0] += 1
      end
    end
    expect(reads).to eq(revision: 2, load: 1)
  end
end
