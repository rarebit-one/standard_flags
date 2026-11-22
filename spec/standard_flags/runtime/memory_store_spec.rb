require "spec_helper"

RSpec.describe StandardFlags::Runtime::MemoryStore do
  subject(:store) { described_class.new }

  it "bumps the revision on every write and keeps member counts" do
    store.put_rule(:x, status: :running)
    store.put_cohort(:staff, unit: :account)
    store.add_member(rule: :x, unit: :account, unit_key: 1, value: true)
    store.add_member(cohort: :staff, unit: :account, unit_key: "1", value: "on")
    store.add_member(cohort: :staff, unit: :account, unit_key: "1", value: "on")
    expect(store.revision).to eq(5)
    loaded = store.load
    expect(loaded.rules.first.member_count).to eq(1)
    expect(loaded.cohorts.first.member_count).to eq(1)

    store.remove_member(rule: :x, unit: :account, unit_key: "1")
    store.remove_member(cohort: :staff, unit: :account, unit_key: "1")
    expect(store.load.rules.first.member_count).to eq(0)
    expect(store.memberships(:account, [ "1" ])).to be_empty
  end

  it "refuses unknown attributes, statuses and owners" do
    expect { store.put_rule(:x, colour: "red") }.to raise_error(ArgumentError, "unknown rule attribute(s): colour")
    expect { store.put_rule(:x, status: :live) }.to raise_error(ArgumentError, /status must be one of/)
    expect { store.add_member(rule: :y, unit: :account, unit_key: "1", value: true) }.to raise_error(ArgumentError, /no rule for :y/)
    expect { store.add_member(cohort: :y, unit: :account, unit_key: "1", value: true) }.to raise_error(ArgumentError, /no cohort/)
    expect { store.add_member(unit: :account, unit_key: "1", value: true) }.to raise_error(ArgumentError, /exactly one/)
  end

  it "hides unit keys from inspect" do
    store.put_rule(:x, status: :running)
    store.add_member(rule: :x, unit: :phone, unit_key: "+6591234567", value: true)
    expect(store.memberships(:phone, [ "+6591234567" ]).first.inspect).not_to include("9123")
  end

  it "is a Store" do
    expect(StandardFlags::Runtime::Store.new.ready?).to be(true)
    %i[revision load].each { |name| expect { StandardFlags::Runtime::Store.new.public_send(name) }.to raise_error(NotImplementedError) }
    expect { StandardFlags::Runtime::Store.new.memberships(:a, []) }.to raise_error(NotImplementedError)
  end
end
