require "spec_helper"
require "pp"

# The runtime read path when actors, stores and stored rows misbehave: it
# keeps answers per unit apart, never raises into the host, and keeps unit
# keys out of reports and consoles.
RSpec.describe "runtime rule read path hardening", registry: RuntimeHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
  end

  def unit_of_work(&)
    Rails.application.executor.wrap(&)
  end

  # Makes the store's membership reads fail; returns a counter of attempts.
  def break_memberships!
    calls = [ 0 ]
    store.define_singleton_method(:memberships) do |*|
      calls[0] += 1
      raise StandardFlags::Runtime::StoreError.new("membership lookup failed: PG::ConnectionBad", cause_class: "PG::ConnectionBad")
    end
    calls
  end

  describe "the per-unit-of-work memo" do
    let(:user) { RuntimeHelpers::User }

    before do
      define_flags(&RuntimeHelpers::USER_BY_PHONE)
      store.put_rule(:beta, status: :running)
      store.add_member(rule: :beta, unit: :user, unit_key: "+15550001", value: true)
    end

    it "keeps unsaved actors (nil id) apart" do
      values = unit_of_work do
        [ "+15550001", "+15550002" ].map { |phone| StandardFlags.on?(:beta, for: { user: user.new(nil, phone) }) }
      end
      expect(values).to eq([ true, false ])
    end

    it "keeps actors apart when the unit key isn't their id" do
      values = unit_of_work do
        [ "+15550001", "+15550002" ].map { |phone| StandardFlags.on?(:beta, for: { user: user.new(7, phone) }) }
      end
      expect(values).to eq([ true, false ])
    end

    it "falls back to object identity for actors without an id" do
      keys = 2.times.map { StandardFlags::Context.new(actors: { user: user.new(nil, "+15550001") }).cache_key }
      expect(keys.uniq.size).to eq(2)
    end

    it "fails only the flag when the unit's key: raises" do
      define_flags do
        unit :user, from: ->(ctx) { ctx.user }, key: ->(user) { user.missing_attribute }
        flag :beta, owner: "growth", remove_by: "2099-01-01", final: true, unit: :user
      end
      evaluation = unit_of_work { 2.times.map { StandardFlags.evaluate(:beta, for: { user: user.new(1, "+15550001") }) } }
      expect(evaluation).to all(have_attributes(value: false, reason: "ERROR", error_code: "GENERAL"))
    end

    it "still answers repeat reads of one actor from the memo" do
      actor = user.new(nil, "+15550001")
      reads = unit_of_work do
        3.times { StandardFlags.on?(:beta, for: { user: actor }) }
        store.reads[:memberships]
      end
      expect(reads).to eq(1)
    end
  end

  describe "StandardFlags.preload" do
    before do
      store.put_rule(:new_checkout, status: :running)
      store.add_member(rule: :new_checkout, unit: :account, unit_key: "1", value: true)
      StandardFlags.evaluate(:global_banner)
    end

    it "returns 0 on a store error, reports it once, and memoises nothing" do
      calls = break_memberships!
      errors = collect_errors do
        unit_of_work do
          2.times { expect(StandardFlags.preload(:account, %w[1 2])).to eq(0) }
          expect(StandardFlags::Memo.key?([ StandardFlags::Runtime::MEMBERSHIPS_MEMO, :account, "1" ])).to be(false)
        end
      end
      expect(calls.first).to eq(2)
      expect(errors.errors_of(StandardFlags::Runtime::StoreError).map(&:message))
        .to eq([ "membership lookup failed: PG::ConnectionBad" ])
    end

    it "returns 0 when the unit's key: raises, reporting the error class but not the value" do
      define_flags do
        unit :phone, from: ->(ctx) { ctx.phone }, key: ->(record) { record.phone_number }
        flag :phone_login, owner: "identity", remove_by: "2099-01-01", final: true, unit: :phone
      end
      store.put_rule(:phone_login, status: :running)
      store.add_member(rule: :phone_login, unit: :phone, unit_key: "+15550001", value: true)
      errors = collect_errors { unit_of_work { expect(StandardFlags.preload(:phone, [ "+15550001" ])).to eq(0) } }
      messages = errors.reports.map { |r| r[:error].message }
      expect(messages).to eq([ "preload failed: NoMethodError" ])
      expect(messages.join).not_to include("5550001")
    end

    it "doesn't raise on a malformed cohort attachment" do
      raw = RuntimeHelpers::RawStore.new(StandardFlags::Runtime::Rule.build(key: :new_checkout, salt: "s", status: "running",
                                                            cohorts: [ 7 ]))
      StandardFlags.config.runtime_store = raw
      unit_of_work { expect(StandardFlags.preload(:account, %w[1])).to eq(0) }
    end
  end

  describe "a failed membership lookup" do
    before do
      StandardFlags.config.refresh_interval = 0
      store.put_rule(:new_checkout, status: :running)
      store.add_member(rule: :new_checkout, unit: :account, unit_key: "9", value: false)
      store.put_rule(:strict_gates, status: :running, fallthrough_value: "sensor")
      store.put_cohort(:staff, unit: :account)
      store.add_member(cohort: :staff, unit: :account, unit_key: "9", value: true)
      store.put_rule(:strict_gates, cohorts: { staff: :on })
      StandardFlags.evaluate(:global_banner)
    end

    it "is tried once per unit per unit of work and reported once" do
      calls = break_memberships!
      errors = collect_errors do
        unit_of_work do
          %i[new_checkout strict_gates].each { |key| StandardFlags.evaluate(key, for: for_account(1)) }
          %w[ios android].each { |p| StandardFlags.evaluate(:new_checkout, for: for_account(1, client: { platform: p })) }
        end
      end
      expect(calls.first).to eq(1)
      expect(errors.errors_of(StandardFlags::Runtime::StoreError).size).to eq(1)
    end

    it "skips members and cohorts and carries on to the split, marked ERROR / GENERAL" do
      store.put_rule(:new_checkout, percentage_bps: 10_000)
      break_memberships!
      expect(StandardFlags.evaluate(:new_checkout, for: for_account(9)))
        .to have_attributes(value: true, reason: "ERROR", error_code: "GENERAL", rule_id: "percentage")
    end

    it "serves the fallthrough, else the code default, marked ERROR / GENERAL" do
      break_memberships!
      expect(StandardFlags.evaluate(:strict_gates, for: for_account(9)))
        .to have_attributes(value: :sensor, reason: "ERROR", error_code: "GENERAL", rule_id: "fallthrough")
      expect(StandardFlags.evaluate(:new_checkout, for: for_account(9)))
        .to have_attributes(value: false, reason: "ERROR", error_code: "GENERAL", rule_id: nil)
    end
  end

  describe "Membership" do
    let(:membership) do
      StandardFlags::Runtime::Membership.new(rule_id: 1, cohort_id: nil, unit: :phone, unit_key: "+15550001",
                                             value: "on", expires_at: nil)
    end

    it "keeps the unit key out of pp and pretty_inspect" do
      expect(PP.pp(membership, +"")).not_to include("5550001")
      expect(membership.pretty_inspect).to eq("#{membership.inspect}\n")
    end
  end

  describe "malformed stored rules" do
    def rule(**attributes)
      StandardFlags::Runtime::Rule.build(key: :new_checkout, salt: "s", status: "running", **attributes)
    end

    {
      "conditions that aren't an object" => { conditions: [ "x" ] },
      "versions that aren't an object" => { conditions: { "platforms" => [ "ios" ], "versions" => "ios >= 2" } },
      "platforms that aren't a list" => { conditions: { "platforms" => 3 } },
      "segments that aren't objects" => { conditions: { "segments" => [ "beta" ] } },
      "a cohort attachment that isn't an object" => { cohorts: [ 7 ] },
      "variant weights that aren't an object" => { variant_weights: [ [ "on", 10_000 ] ] }
    }.each do |label, attributes|
      it "fails only the flag with PARSE_ERROR for #{label}" do
        StandardFlags.config.runtime_store = RuntimeHelpers::RawStore.new(rule(**attributes))
        StandardFlags.config.segment_resolver = ->(*) { true }
        evaluation = nil
        events = capture_events(/rule_invalid/) do
          evaluation = StandardFlags.evaluate(:new_checkout, for: for_account(1, client: { platform: "ios", version: "3.0" }))
        end
        expect(evaluation).to have_attributes(value: false, reason: "ERROR", error_code: "PARSE_ERROR")
        expect(events.map(&:first)).to eq([ "rule_invalid.standard_flags" ])
        expect(StandardFlags.evaluate(:global_banner).reason).to eq("DEFAULT")
      end
    end
  end

  describe "one snapshot per unit of work" do
    before do
      StandardFlags.config.refresh_interval = 0
      store.put_rule(:new_checkout, status: :running, fallthrough_value: true)
      store.put_rule(:strict_gates, status: :running, fallthrough_value: "sensor")
    end

    it "keeps the first evaluation's revision for the rest of the run" do
      seen = unit_of_work do
        first = StandardFlags.on?(:new_checkout, for: for_account(1))
        store.put_rule(:new_checkout, fallthrough_value: false)
        store.put_rule(:strict_gates, fallthrough_value: "on")
        [ first, StandardFlags.on?(:new_checkout, for: for_account(2)), StandardFlags.evaluate(:strict_gates, for: for_account(1)).value ]
      end
      expect(seen).to eq([ true, true, :sensor ])
      expect(unit_of_work { StandardFlags.on?(:new_checkout, for: for_account(2)) }).to be(false)
    end

    it "reads the current snapshot on every evaluation outside a unit of work" do
      expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(true)
      store.put_rule(:new_checkout, fallthrough_value: false)
      expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(false)
    end
  end

  describe "boot" do
    it "registers the filter and leaves a configured store alone" do
      StandardFlags.config.runtime_store = store
      StandardFlags::Runtime.boot!
      expect(StandardFlags::Runtime.store).to equal(store)
      expect(StandardFlags::Runtime).to be_ready
    end

    it "adds unit_key to a filter list once" do
      base = Struct.new(:filter_attributes).new([ :password ])
      2.times { StandardFlags::Runtime.filter_unit_keys!(base) }
      expect(base.filter_attributes).to eq(%i[password unit_key])
    end
  end
end
