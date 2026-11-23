require "spec_helper"

# The operator reads (Store#members, Store#members_at) and the versioning of
# changed memberships that members_at relies on, on MemoryStore. The same
# behaviour on Postgres is in spec/db/restore_spec.rb.
RSpec.describe "member reads", registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:ops) { OperationHelpers::Ops }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
  end

  def tick
    sleep 0.002
    Time.now.tap { sleep 0.002 }
  end

  describe "Store#members" do
    it "pages an owner's memberships, expired ones included, oldest first" do
      store.put_rule(:new_checkout, status: :running)
      %w[a b c].each_with_index { |key, i| store.add_member(rule: :new_checkout, unit: :account, unit_key: key, value: true, created_at: Time.now + i) }
      page = store.members(rule: :new_checkout, offset: 1, limit: 1)
      expect([ page.total, page.memberships.map(&:unit_key), store.members(rule: :new_checkout).memberships.size ]).to eq([ 3, %w[b], 3 ])
      expect(store.members(rule: :home_hero)).to have_attributes(total: 0, memberships: [])
      expect(store.members(cohort: :ghost)).to have_attributes(total: 0)
      expect { store.members }.to raise_error(ArgumentError, /exactly one/)
    end
  end

  describe "Store#members_at" do
    it "reads the memberships as they were: created by then, not yet removed or expired" do
      op!(ops::AddMembers, :new_checkout, keys: %w[kept removed])
      op!(ops::AddMembers, :new_checkout, keys: %w[expiring], expires_at: Time.now + 0.05)
      at = tick
      op!(ops::AddMembers, :new_checkout, keys: %w[later])
      op!(ops::RemoveMembers, :new_checkout, keys: %w[removed])
      expect(store.members_at(at, rule: :new_checkout).map(&:unit_key)).to eq(%w[kept expiring removed])
      sleep 0.06
      expect(store.members_at(Time.now, rule: :new_checkout).map(&:unit_key)).to eq(%w[kept later])
      expect(store.members_at(at, rule: :home_hero)).to eq([])
    end
  end

  describe "a changed membership" do
    it "is versioned: the old row is kept as removed, so members_at reads the old value" do
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731], value: true)
      at = tick
      changed = op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731], value: false)
      expect(changed.value).to include(added: 0, updated: 1)
      expect(store.members(rule: :new_checkout).memberships.map(&:value)).to eq(%w[off])
      expect(store.members_at(at, rule: :new_checkout).map(&:value)).to eq(%w[on])
      expect(store.removed_memberships.map(&:value)).to eq(%w[on])
      expect(store.rule(:new_checkout).member_count).to eq(1)
    end

    it "is left alone when re-added unchanged" do
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731])
      created = store.members(rule: :new_checkout).memberships.first.created_at
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731])
      expect(store.members(rule: :new_checkout).memberships.map(&:created_at)).to eq([ created ])
      expect(store.removed_memberships).to be_empty
    end
  end

  describe "a store without operator reads" do
    it "raises StoreError, which the tools turn into a store_error" do
      raw = RuntimeHelpers::RawStore.new
      expect { raw.members(rule: :x) }.to raise_error(StandardFlags::Runtime::StoreError, /does not support listing members/)
      expect { raw.members_at(Time.now, rule: :x) }.to raise_error(StandardFlags::Runtime::StoreError, /does not support reading past members/)
    end
  end

  describe "Registry#with_unit_key" do
    it "resolves the unit to the key for every context, leaving the registry as it was" do
      probe = StandardFlags.registry.with_unit_key(:phone, "+6591234567")
      expect(probe.units[:phone].key_from(StandardFlags::Context.empty)).to eq("+6591234567")
      expect(probe[:phone_login]).to equal(StandardFlags.registry[:phone_login])
      expect(probe.tombstoned?(:old_banner)).to be(true)
      expect(StandardFlags.registry.units[:phone].key_for("+65 9123")).to eq("+659123")
      expect { StandardFlags.registry.with_unit_key(:nope, "x") }.to raise_error(ArgumentError, "unknown unit :nope")
    end
  end

  describe StandardFlags::AuditTrail do
    # Answers the query API calls AuditTrail makes, from fixed rows.
    let(:log) do
      Class.new do
        attr_reader :queries

        def initialize(rows)
          @rows = rows
          @queries = []
        end

        def where(*args, **kwargs)
          @queries << (args.empty? ? kwargs : args)
          self
        end

        def reverse_chronological = self
        def limit(_) = self
        def pluck(*columns) = columns == [ :metadata ] ? @rows.map(&:last) : @rows
      end
    end

    it "takes each rule's after-state with the highest revision, parsing JSON text" do
      rows = [
        [ "standard_flags.flag.ramped", Time.utc(2026, 11, 20), { "key" => "a", "after" => { "lock_version" => 2, "status" => "running" } } ],
        [ "standard_flags.flag.started", Time.utc(2026, 11, 20), JSON.generate("key" => "a", "after" => { "lock_version" => 3, "status" => "paused" }) ],
        [ "standard_flags.flag.paused", Time.utc(2026, 11, 20), { "key" => "b", "after" => "not a state" } ],
        [ "standard_flags.cohort.created", Time.utc(2026, 11, 20), { "cohort" => "staff" } ],
        [ "standard_flags.flag.paused", Time.utc(2026, 11, 20), nil ]
      ]
      fake = log.new(rows)
      states = described_class.new(fake).rule_states(Time.utc(2026, 11, 21))
      expect(states).to eq(a: { "lock_version" => 3, "status" => "paused" })
      expect(fake.queries.first).to eq(event_type: described_class::RULE_EVENTS)
      expect(fake.queries.last[:occurred_at]).to eq(..Time.utc(2026, 11, 21))
    end

    it "lists a flag's recent entries without anything but labels, reasons and revisions" do
      rows = [ [ "standard_flags.flag.ramped", Time.utc(2026, 11, 20, 9), { "actor_label" => "User:1", "reason" => "canary", "revision" => 4, "after" => {} } ] ]
      expect(described_class.new(log.new(rows)).entries(:new_checkout)).to eq(
        [ { event: "standard_flags.flag.ramped", occurred_at: "2026-11-20T09:00:00Z", actor: "User:1", reason: "canary", revision: 4 } ]
      )
    end

    it "is available only with standard_audit's AuditLog loaded" do
      expect(described_class.available?).to be(false)
      stub_const("StandardAudit::AuditLog", Class.new)
      expect(described_class.available?).to be(true)
    end
  end
end
