require "spec_helper"

RSpec.describe StandardFlags::Runtime, ".purge!", registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:ops) { OperationHelpers::Ops }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
  end

  it "deletes removed and expired memberships past retention, keeping member_count in step" do
    store.put_rule(:new_checkout, status: :running)
    store.add_member(rule: :new_checkout, unit: :account, unit_key: "1", value: true, expires_at: Time.now - 100 * 86_400)
    store.add_member(rule: :new_checkout, unit: :account, unit_key: "2", value: true, expires_at: Time.now - 86_400)
    store.add_member(rule: :new_checkout, unit: :account, unit_key: "3", value: true)
    op!(ops::RemoveMembers, :new_checkout, keys: [ "3" ])

    expect(store.purgeable(before: Time.now - 90 * 86_400)).to eq(removed: 0, expired: 1)
    expect(described_class.purge!).to eq(removed: 0, expired: 1)
    expect(store.rule(:new_checkout).member_count).to eq(1)
    expect(described_class.purge!(before: Time.now + 1)).to eq(removed: 1, expired: 1)
    expect([ store.removed_memberships, store.rule(:new_checkout).member_count ]).to eq([ [], 0 ])
  end

  it "has a job" do
    store.put_cohort(:staff, unit: :account)
    store.add_member(cohort: :staff, unit: :account, unit_key: "1", value: "on", expires_at: Time.now - 100 * 86_400)
    StandardFlags::PurgeJob.perform_now
    expect(store.load.cohorts.first.member_count).to eq(0)

    StandardFlags.config.runtime_rules = false
    StandardFlags.config.runtime_store = nil
    expect(StandardFlags::PurgeJob.perform_now).to be_nil
  end

  it "refuses on a store that can't purge" do
    plain = Class.new(StandardFlags::Runtime::Store).new
    StandardFlags.config.runtime_store = plain
    expect { described_class.purge! }.to raise_error(StandardFlags::Runtime::StoreError, /does not support purge/)
    expect { plain.purgeable(before: Time.now) }.to raise_error(StandardFlags::Runtime::StoreError, /does not support purge/)
    expect(plain.touch_evaluated([ :x ], before: Time.now)).to be_nil
  end
end
