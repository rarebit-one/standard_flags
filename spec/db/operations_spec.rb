require "spec_helper"

RSpec.describe "the write path on Postgres", :db, registry: OperationHelpers::REGISTRY do
  let(:models) { StandardFlags::Runtime::Models }
  let(:ops) { OperationHelpers::Ops }
  let(:time) { [ 0.0 ] }

  before do
    require "standard_flags/runtime/active_record_store"
    StandardFlags.config.runtime_rules = true
    StandardFlags::Runtime.clock = -> { time.first }
  end

  def revision
    models::State.pick(:revision)
  end

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  describe "every operation against the tables" do
    before do
      op!(ops::CreateCohort, "staff", unit: :account, name: "Staff")
      op!(ops::AddMembers, "cohort:staff", keys: %w[acct-7731 acct-7732])
      op!(ops::Ramp, :strict_gates, bps: 2_500, value: :on)
      op!(ops::SetVariants, :home_hero, weights: { control: 5_000, savings: 5_000 })
      op!(ops::SetValue, :strict_gates, value: :sensor)
      op!(ops::SetConditions, :strict_gates, platforms: %w[ios], versions: { ios: ">= 2.0" })
      op!(ops::AttachCohort, :strict_gates, cohort: "staff", value: :on)
      op!(ops::AddMembers, :strict_gates, keys: [ "acct-7733" ], value: :off, expires_at: Time.now + 3_600)
      op!(ops::RemoveMembers, "cohort:staff", keys: [ "acct-7732" ])
      op!(ops::Start, :strict_gates)
    end

    it "writes the rule, one revision per operation" do
      expect(revision).to eq(10)
      rule = models::Rule.find_by!(key: "strict_gates")
      expect(rule).to have_attributes(status: "running", hash_version: 2, percentage_bps: 2_500, rollout_value: "on",
                                      fallthrough_value: "sensor", member_count: 1, lock_version: 6,
                                      cohorts: [ { "cohort" => "staff", "value" => "on" } ],
                                      conditions: { "platforms" => [ "ios" ], "versions" => { "ios" => ">= 2.0" } })
      expect(rule.salt).to match(/\A\h{32}\z/)
    end

    it "keeps member counts and soft-deletes removed members" do
      expect(models::Cohort.find_by!(key: "staff").member_count).to eq(1)
      expect(models::Membership.where.not(removed_at: nil).pluck(:unit_key)).to eq(%w[acct-7732])
    end

    it "serves what was written" do
      expect(StandardFlags.evaluate(:strict_gates, for: for_account("acct-7731"))).to have_attributes(value: :on, rule_id: "cohort:staff")
      expect(StandardFlags.evaluate(:strict_gates, for: for_account("acct-7733"))).to have_attributes(value: :off, rule_id: "deny")
      expect(StandardFlags.evaluate(:strict_gates, for: for_account("acct-7732")).rule_id).to eq("fallthrough")
    end

    it "pauses, detaches, archives and stops" do
      op!(ops::Pause, :strict_gates)
      op!(ops::DetachCohort, :strict_gates, cohort: "staff")
      op!(ops::ArchiveCohort, "staff")
      op!(ops::Stop, :strict_gates, serve: :on)
      expect(StandardFlags.evaluate(:strict_gates, for: for_account("acct-7733"))).to have_attributes(value: :on, rule_id: "stopped")
      expect(models::Cohort.find_by!(key: "staff").archived_at).not_to be_nil
    end
  end

  it "copies a declared bucketing: and re-adds a removed member as a new live row" do
    op!(ops::AddMembers, :legacy_ramp, keys: [ "1" ])
    op!(ops::RemoveMembers, :legacy_ramp, keys: [ "1" ])
    op!(ops::AddMembers, :legacy_ramp, keys: [ "1" ], value: false)
    expect(models::Rule.find_by!(key: "legacy_ramp")).to have_attributes(hash_version: 1, salt: "legacy-salt", member_count: 1)
    expect(models::Membership.order(:created_at).pluck(:value, :removed_at).map { |v, r| [ v, r.nil? ] }).to eq([ [ "on", false ], [ "off", true ] ])
  end

  it "lets exactly one of two writers holding the same revision win" do
    op!(ops::Ramp, :new_checkout, bps: 100)
    gate = Queue.new
    threads = [ 200, 300 ].map do |bps|
      in_thread do
        gate.pop
        op(ops::Ramp, :new_checkout, bps: bps, expected_revision: 1)
      end
    end
    2.times { gate << true }
    results = threads.map(&:value)
    expect(results.map(&:success?).sort_by { |s| s ? 0 : 1 }).to eq([ true, false ])
    expect(results.reject(&:success?).map(&:code)).to eq([ :stale_revision ])
    expect(models::Rule.find_by!(key: "new_checkout").lock_version).to eq(2)
    expect(revision).to eq(2)
  end

  it "creates a rule once when two writers use it first at the same time" do
    gate = Queue.new
    threads = 2.times.map do
      in_thread do
        gate.pop
        op(ops::AddMembers, :new_checkout, keys: [ "1" ])
      end
    end
    2.times { gate << true }
    expect(threads.map(&:value)).to all(be_success)
    expect(models::Rule.where(key: "new_checkout").count).to eq(1)
    expect(models::Rule.find_by!(key: "new_checkout")).to have_attributes(lock_version: 2, member_count: 1)
  end

  it "commits and rolls back with the host's own transaction" do
    models::Record.transaction do
      op!(ops::Ramp, :new_checkout, bps: 100)
      raise ActiveRecord::Rollback
    end
    expect(models::Rule.count).to eq(0)
    expect(revision).to eq(0)
  end

  # An evaluation inside a write's transaction loads the uncommitted rules
  # under the new revision; the transaction rolls back; a later write must
  # not commit under the same number, or the process would keep serving the
  # rolled-back rules.
  it "never reuses a rolled-back revision, so a process that saw it reloads" do
    op!(ops::SetValue, :global_banner, value: false)
    op!(ops::Start, :global_banner)
    models::Record.transaction do
      op!(ops::SetValue, :global_banner, value: true)
      expect(StandardFlags.on?(:global_banner)).to be(true) # uncommitted, cached
      raise ActiveRecord::Rollback
    end
    phantom = StandardFlags::Runtime.snapshot.revision

    written = op!(ops::Ramp, :new_checkout, bps: 100).value[:store_revision]
    expect(written).not_to eq(phantom)
    time[0] += 5
    expect(StandardFlags.on?(:global_banner)).to be(false)
    expect(StandardFlags::Runtime.snapshot.revision).to eq(written)
  end

  it "reloads on any change of revision, even one that goes down" do
    op!(ops::SetValue, :global_banner, value: true)
    op!(ops::Start, :global_banner)
    expect(StandardFlags.on?(:global_banner)).to be(true)
    models::Rule.where(key: "global_banner").update_all(fallthrough_value: "off")
    models::State.update_all(revision: 1)
    time[0] += 5
    expect(StandardFlags.on?(:global_banner)).to be(false)
  end

  it "rolls back a write that breaks a limit" do
    StandardFlags.config.max_members = 1
    expect(op(ops::AddMembers, :new_checkout, keys: %w[1 2]).code).to eq(:limit_exceeded)
    expect([ models::Rule.count, models::Membership.count, revision ]).to eq([ 0, 0, 0 ])
  end

  it "reports a database error without the driver's message, which can quote a unit key" do
    allow(StandardFlags::Runtime::ActiveRecordStore::Transaction).to receive(:new).and_wrap_original do |original|
      original.call.tap do |tx|
        allow(tx).to receive(:insert_members).and_raise(ActiveRecord::RecordNotUnique, "Key (unit_key)=(acct-7731) already exists")
      end
    end
    result = nil
    errors = collect_errors { result = op(ops::AddMembers, :new_checkout, keys: [ "acct-7731" ]) }
    expect(result).to have_attributes(code: :store_error, errors: [ "write failed: ActiveRecord::RecordNotUnique" ])
    expect_no_unit_keys(result, errors.reports.map { |r| [ r[:error].message, r[:context], r[:error].cause ] })
  end

  it "purges removed and expired memberships past retention, recounting and bumping the revision" do
    op!(ops::AddMembers, :new_checkout, keys: %w[1 2 3])
    op!(ops::RemoveMembers, :new_checkout, keys: %w[1])
    models::Membership.where(unit_key: "1").update_all(removed_at: Time.now - 100 * 86_400)
    models::Membership.where(unit_key: "2").update_all(expires_at: Time.now - 100 * 86_400)
    before = revision

    expect(StandardFlags::Runtime.store.purgeable(before: Time.now - 90 * 86_400)).to eq(removed: 1, expired: 1)
    expect(StandardFlags::Runtime.purge!).to eq(removed: 1, expired: 1)
    expect(models::Membership.pluck(:unit_key)).to eq(%w[3])
    expect([ models::Rule.find_by!(key: "new_checkout").member_count, revision ]).to eq([ 1, before + 1 ])
    expect(StandardFlags::Runtime.purge!).to eq(removed: 0, expired: 0)
  end

  it "lists stale rules from the tables" do
    op!(ops::Ramp, :new_checkout, bps: 10_000)
    models::Rule.where(key: "new_checkout").update_all(full_since: Time.now - 40 * 86_400, last_evaluated_at: Time.now)
    expect(StandardFlags::Tooling::Stale.new.runtime_findings.first).to include("rule :new_checkout has served 100% since")
  end

  describe "last_evaluated_at" do
    before do
      StandardFlags.config.evaluation_tracking_interval = 60
      op!(ops::SetValue, :new_checkout, value: true)
      op!(ops::Start, :new_checkout)
      op!(ops::SetValue, :strict_gates, value: :on)
      op!(ops::Start, :strict_gates)
      op!(ops::Pause, :strict_gates)
    end

    def unit_of_work(&)
      Rails.application.executor.wrap(&)
    end

    def evaluate_for(seconds)
      seconds.times do
        unit_of_work do
          StandardFlags.evaluate(:new_checkout, for: for_account(1))
          StandardFlags.evaluate(:strict_gates, for: for_account(1))
        end
        time[0] += 1
      end
    end

    it "writes once per interval, in one UPDATE" do
      queries = DatabaseHelpers.queries { evaluate_for(30) }
      updates = queries.grep(/\AUPDATE "standard_flags_rules" SET last_evaluated_at/)
      expect(updates.size).to eq(1)
      expect(updates.first).to include('"standard_flags_rules"."key" IN', "last_evaluated_at IS NULL OR last_evaluated_at <",
                                       "FOR UPDATE SKIP LOCKED")
      expect(updates.first).not_to include("lock_version", "updated_at")
      expect(models::Rule.where.not(last_evaluated_at: nil).pluck(:key)).to match_array(%w[new_checkout strict_gates])

      queries = DatabaseHelpers.queries { evaluate_for(60) }
      expect(queries.grep(/last_evaluated_at/).size).to eq(1)
    end

    it "skips the write inside a transaction and makes it after" do
      models::Record.transaction { evaluate_for(12) }
      expect(models::Rule.where.not(last_evaluated_at: nil).count).to eq(0)
      evaluate_for(6)
      expect(models::Rule.where.not(last_evaluated_at: nil).count).to eq(2)
    end

    it "swallows a failing write and reports it once" do
      allow(models::Rule).to receive(:where).and_call_original
      allow(models::Rule).to receive(:where).with(key: %w[new_checkout strict_gates]).and_raise(ActiveRecord::StatementInvalid, "boom")
      errors = collect_errors { evaluate_for(30) }
      expect(errors.reports.map { |r| r[:error].message }).to eq([ "evaluation tracking failed: ActiveRecord::StatementInvalid" ])
      expect(StandardFlags.on?(:new_checkout, for: for_account(1))).to be(true)
    end
  end
end
