require "spec_helper"

# Restore, the operator reads and the admin's audit entries against
# Postgres: the memberships table read as of a past time, and rule history
# read back from an audit_logs table that a stand-in for standard_audit
# writes (its query API: AuditLog with `where`, `reverse_chronological`,
# `pluck`; its Operation contract: `audits`, `audit!`).
RSpec.describe "restore and operator reads on Postgres", :db, registry: OperationHelpers::REGISTRY do
  let(:models) { StandardFlags::Runtime::Models }
  let(:ops) { OperationHelpers::Ops }

  def self.audit_log
    @audit_log ||= Class.new(ActiveRecord::Base) do
      self.table_name = "audit_logs"
      scope :reverse_chronological, -> { order(occurred_at: :desc, created_at: :desc) }
    end
  end

  def install_standard_audit
    log = self.class.audit_log
    config = Struct.new(:enabled, :subscriptions, :raise_on_audit_write_error).new(true, [], true)
    operation = Module.new do
      def self.included(base)
        base.extend(Module.new { def audits(*) = nil })
      end

      private

      define_method(:audit!) do |action, actor: nil, metadata: {}, **|
        log.create!(event_type: action, actor_type: actor&.class&.name, metadata: metadata, occurred_at: Time.current)
      end
    end
    operation.const_set(:DeclarationError, Class.new(StandardError))
    audit = Module.new { define_singleton_method(:config) { config } }
    audit.const_set(:Operation, operation)
    audit.const_set(:AuditLog, log)
    stub_const("StandardAudit", audit)
  end

  before do
    require "standard_flags/runtime/active_record_store"
    StandardFlags.config.runtime_rules = true
    install_standard_audit
  end

  after { StandardFlags::Operations::Audit.reset! }

  def rule_state(key)
    models::Rule.find_by!(key: key.to_s).attributes.slice(*%w[status percentage_bps rollout_value variant_weights fallthrough_value
                                                              stop_value conditions cohorts member_count])
  end

  def live(owner_column, id)
    models::Membership.where(owner_column => id, removed_at: nil).order(:unit_key).pluck(:unit_key, :value)
  end

  describe "a round trip: change, change, restore to the first, compare" do
    let(:at) { checkpoint }
    let(:first) do
      { rule: rule_state(:new_checkout), gates: rule_state(:strict_gates), members: live(:rule_id, rule_id), cohort: live(:cohort_id, cohort_id) }
    end

    before do
      op!(ops::CreateCohort, "staff", unit: :account)
      op!(ops::AddMembers, "cohort:staff", keys: %w[acct-7731])
      op!(ops::Ramp, :new_checkout, bps: 500)
      op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731 acct-7732])
      op!(ops::AddMembers, :new_checkout, keys: %w[+6591234567], value: false)
      op!(ops::Start, :new_checkout)
      op!(ops::SetValue, :strict_gates, value: :sensor)
      at
      first
      op!(ops::Pause, :new_checkout)
      op!(ops::Ramp, :new_checkout, bps: 9_000)
      op!(ops::DetachCohort, :new_checkout, cohort: "staff")
      op!(ops::RemoveMembers, :new_checkout, keys: %w[acct-7731])
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7732], value: false) # a value change, versioned
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7734])
      op!(ops::AddMembers, "cohort:staff", keys: %w[acct-7735])
      op!(ops::SetValue, :strict_gates, value: :on)
      op!(ops::SetVariants, :home_hero, weights: { control: 5_000, savings: 5_000 })
      op!(ops::Start, :home_hero)
    end

    def rule_id = models::Rule.find_by!(key: "new_checkout").id
    def cohort_id = models::Cohort.find_by!(key: "staff").id

    def restore!(**options)
      StandardFlags::Operations::Restore.call(at: at, reason: "bad ramp", **options)
    end

    it "reads the history from audit_logs and applies each target in one write, with one row" do
      result = restore!(apply: true)
      expect(result).to be_success, -> { result.inspect }
      expect(result.value[:entries].to_h { |e| [ e[:target], e[:status] ] })
        .to eq("cohort:staff" => "applied", "home_hero" => "skipped", "new_checkout" => "applied", "strict_gates" => "applied")
      expect(self.class.audit_log.where("metadata->>'reason' = ?", "restore to #{at.utc.iso8601}: bad ramp").order(:occurred_at).pluck(:event_type))
        .to eq(%w[standard_flags.cohort.restored standard_flags.flag.restored standard_flags.flag.restored])
      expect(restore!.value[:entries].map { |e| e[:status] }.uniq).to eq(%w[unchanged skipped])
    end

    it "puts rules, members and what they serve back as they were" do
      expect(rule_state(:new_checkout)).not_to eq(first[:rule])
      restore!(apply: true)
      expect([ rule_state(:new_checkout), rule_state(:strict_gates), models::Rule.find_by!(key: "home_hero").status ])
        .to eq([ first[:rule], first[:gates], "running" ]) # no audit history at T: left alone
      expect([ live(:rule_id, rule_id), live(:cohort_id, cohort_id) ]).to eq([ first[:members], first[:cohort] ])
      expect(StandardFlags.evaluate(:new_checkout, for: for_account("acct-7732"))).to have_attributes(value: true, rule_id: "allow")
    end

    it "keeps unit keys out of its result, the audit rows and SQL text" do
      result = nil
      statements = DatabaseHelpers.queries { result = restore!(apply: true) }
      expect(result).to be_success
      expect_no_unit_keys(result.value, statements, self.class.audit_log.pluck(:metadata))
    end
  end

  describe "the memberships table as of a time" do
    let(:store) { StandardFlags::Runtime.store }
    let(:at) { checkpoint }

    before do
      op!(ops::AddMembers, :new_checkout, keys: %w[kept removed])
      op!(ops::AddMembers, :new_checkout, keys: %w[expiring], expires_at: Time.now + 0.3)
      op!(ops::AddMembers, :new_checkout, keys: %w[changed], value: true)
      at
      op!(ops::AddMembers, :new_checkout, keys: %w[later])
      op!(ops::RemoveMembers, :new_checkout, keys: %w[removed])
      op!(ops::AddMembers, :new_checkout, keys: %w[changed], value: false)
    end

    it "is read from rows created by then and not removed or expired then, at their value then" do
      past = store.members_at(at, rule: :new_checkout)
      expect(past.map { |m| [ m.unit_key, m.value ] }).to contain_exactly([ "kept", "on" ], [ "removed", "on" ], [ "expiring", "on" ], [ "changed", "on" ])
      expect(past.map(&:created_at)).to all(be <= at)
      expect(models::Membership.where(unit_key: "changed").order(:created_at).pluck(:value, Arel.sql("removed_at IS NULL")))
        .to eq([ [ "on", false ], [ "off", true ] ])
      expect(store.members_at(at, cohort: :ghost)).to eq([])
    end

    it "drops what expired" do
      sleep 0.35
      expect(store.members_at(Time.now, rule: :new_checkout).map(&:unit_key)).to contain_exactly("kept", "later", "changed")
    end

    it "pages the live rows" do
      page = store.members(rule: :new_checkout, offset: 1, limit: 2)
      expect([ page.total, page.memberships.map(&:unit_key) ]).to eq([ 4, %w[expiring later] ])
      expect(store.members(rule: :home_hero)).to have_attributes(total: 0, memberships: [])
    end
  end

  it "leaves a re-added unchanged member alone" do
    op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731])
    expect { op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731]) }.not_to(change { models::Membership.pluck(:id, :updated_at) })
  end

  it "masks members through the MCP tool, and never puts a unit key into SQL text" do
    StandardFlags.config.authorize = ->(*) { true }
    op!(ops::AddMembers, :new_checkout, keys: OperationHelpers::SECRET_KEYS)
    page = nil
    statements = DatabaseHelpers.queries do
      page = StandardFlags::MCP.tool("list_members").call({ "key" => "new_checkout" }, actor: OperationHelpers::User.new(1))
    end
    expect(page["members"].map { |m| m["unit_key"] }).to eq(%w[•••7731 •••7732 •••4567])
    expect_no_unit_keys(page, statements)
  end

  it "lists a flag's recent audit entries for the admin page" do
    op!(ops::Ramp, :new_checkout, bps: 500)
    op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731])
    op!(ops::Ramp, :strict_gates, bps: 100, value: :on)
    entries = StandardFlags::AuditTrail.new.entries(:new_checkout)
    expect(entries.map { |e| [ e[:event], e[:actor], e[:reason], e[:revision] ] })
      .to eq([ [ "standard_flags.flag.members_added", "system:spec", "spec", 2 ], [ "standard_flags.flag.ramped", "system:spec", "spec", 1 ] ])
    expect(entries.first[:occurred_at]).to match(/\A\d{4}-\d\d-\d\dT.*Z\z/)
  end
end
