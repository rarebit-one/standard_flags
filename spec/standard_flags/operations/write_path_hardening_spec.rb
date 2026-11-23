require "spec_helper"

# Write-path guarantees against the in-memory store. The Postgres side is in
# spec/db/write_path_hardening_spec.rb.
RSpec.describe "write path hardening", registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:ops) { OperationHelpers::Ops }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
  end

  describe "revisions" do
    it "returns the revision expected_revision is checked against, even after other flags' writes" do
      op!(ops::Ramp, :strict_gates, bps: 100, value: :on) # moves the store's revision
      first = op!(ops::Ramp, :new_checkout, bps: 100)
      expect(first.value).to include(revision: first.value[:rule][:lock_version], store_revision: store.revision)

      second = op(ops::Ramp, :new_checkout, bps: 200, expected_revision: first.value[:revision])
      expect(second).to be_success, -> { second.inspect }
    end

    it "refuses a client's stale revision instead of losing another client's update" do
      op!(ops::Ramp, :strict_gates, bps: 100, value: :on)
      seen = op!(ops::Ramp, :new_checkout, bps: 100)  # client A keeps this revision
      op!(ops::Ramp, :new_checkout, bps: 9_000)       # client B ramps to 90%
      late = op(ops::Ramp, :new_checkout, bps: 50, expected_revision: seen.value[:revision])

      expect(late.code).to eq(:stale_revision)
      expect(store.rule(:new_checkout).percentage_bps).to eq(9_000)
    end

    it "uses the store's revision for both on cohort operations" do
      created = op!(ops::CreateCohort, "beta", unit: :account)
      expect(created.value).to include(revision: store.revision, store_revision: store.revision)
      expect(op(ops::AddMembers, "cohort:beta", keys: %w[a1], expected_revision: created.value[:revision])).to be_success
    end
  end

  describe "a running rule after any change" do
    it "refuses clearing the variant weights a percentage still needs" do
      op!(ops::SetVariants, :home_hero, weights: { control: 5_000, savings: 5_000 })
      op!(ops::Ramp, :home_hero, bps: 10_000) # allowed: the weights serve the percentage
      op!(ops::Start, :home_hero)

      cleared = op(ops::SetVariants, :home_hero, weights: {})
      expect(cleared.code).to eq(:invalid)
      expect(cleared.errors.first).to include("has a percentage but no rollout value or variant weights")
      expect(StandardFlags.evaluate(:home_hero, for: for_account("a1"))).to have_attributes(rule_id: "variants", error_code: nil)
    end

    it "allows the same edit while the rule is a draft; Start then refuses it" do
      op!(ops::SetVariants, :home_hero, weights: { control: 5_000, savings: 5_000 })
      op!(ops::Ramp, :home_hero, bps: 10_000)
      op!(ops::SetVariants, :home_hero, weights: {})
      expect(op(ops::Start, :home_hero).code).to eq(:invalid)
    end

    it "refuses a change to a running rule whose stored shape the read path rejects, naming the field" do
      store.put_rule(:new_checkout, status: :running, fallthrough_value: true, conditions: { "segments" => "beta" })
      result = op(ops::SetValue, :new_checkout, value: false)
      expect(result).to have_attributes(code: :invalid, errors: [ ":new_checkout's stored rule has a malformed conditions.segments (expected a list)" ])
    end
  end

  it "refuses to start a hand-edited rule with a malformed shape as :invalid, not :error" do
    store.put_rule(:new_checkout, status: :draft, fallthrough_value: true, conditions: { "versions" => [ ">= 1.0" ] })
    result = op(ops::Start, :new_checkout)
    expect(result).to have_attributes(code: :invalid, errors: [ ":new_checkout's stored rule has a malformed conditions.versions (expected an object)" ])
  end

  describe "cohort authorisation" do
    let(:calls) { [] }

    before do
      op!(ops::CreateCohort, "vip", unit: :account)
      calls = self.calls
      StandardFlags.config.authorize = lambda do |_actor, scope, key|
        calls << [ scope, key ]
        !key.to_s.start_with?("cohort:vip")
      end
    end

    it "asks the policy about the cohort as well as the flag when attaching" do
      result = ops::AttachCohort.call(:new_checkout, cohort: "vip", value: true, actor: system_actor, reason: "x")
      expect(result).to have_attributes(code: :unauthorized)
      expect(result.errors.first).to include('"cohort:vip"')
      expect(calls).to eq([ [ "flags:write", :new_checkout ], [ "flags:write", "cohort:vip" ] ])
      expect(store.rule(:new_checkout)).to be_nil
    end

    it "asks about both when detaching" do
      store.put_rule(:new_checkout, status: :draft, cohorts: { vip: true })
      result = ops::DetachCohort.call(:new_checkout, cohort: "cohort:vip", actor: system_actor, reason: "x")
      expect(result.code).to eq(:unauthorized)
      expect(calls.last).to eq([ "flags:write", "cohort:vip" ])
    end
  end

  describe "after the commit" do
    def lock_held?
      store.instance_variable_get(:@mutex).mon_locked?
    end

    it "publishes the event and change.standard_flags, and expires the cache, once the write's lock is released" do
      seen = []
      subscriber = ActiveSupport::Notifications.subscribe(/\Astandard_flags\.flag\.|\Achange\.standard_flags\z/) do |name, *|
        seen << [ name, lock_held? ]
      end
      op!(ops::Ramp, :new_checkout, bps: 500)
      expect(seen).to eq([ [ "standard_flags.flag.ramped", false ], [ "change.standard_flags", false ] ])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "runs config.add_notifier callables after the commit" do
      held = []
      StandardFlags.config.add_notifier(->(name, _payload) { held << lock_held? if name == "change.standard_flags" })
      StandardFlags.subscribers.setup!
      op!(ops::SetValue, :strict_gates, value: :on)
      expect(held).to eq([ false ])
    ensure
      StandardFlags.subscribers.teardown!
    end

    it "still succeeds when an after-commit step fails, since the change is in" do
      allow(StandardFlags::Runtime).to receive(:expire!).and_raise(IOError)
      result = nil
      expect { result = op(ops::Ramp, :new_checkout, bps: 500) }.to output(/after-commit step of ramp failed: IOError/).to_stderr
      expect(result).to be_success
      expect(store.rule(:new_checkout).percentage_bps).to eq(500)
    end

    it "announces nothing for a write that rolls back" do
      allow(StandardFlags::Runtime).to receive(:bump_revision!).and_raise(StandardFlags::Runtime::StoreError, "write failed: IOError")
      events = events_during { expect(op(ops::Ramp, :new_checkout, bps: 500).code).to eq(:store_error) }
      expect(events).to eq([])
    end
  end
end
