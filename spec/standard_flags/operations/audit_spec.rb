require "spec_helper"

# Against a stand-in for the part of standard_audit's public API the gem
# uses: StandardAudit.config (enabled, subscriptions), StandardAudit.record,
# and StandardAudit::Operation (audits, audit!, DeclarationError). Each row
# the stand-in "writes" lands in `rows`, whichever path wrote it.
RSpec.describe StandardFlags::Operations::Audit, registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:rows) { [] }
  let(:audit_config) { Struct.new(:enabled, :subscriptions, :raise_on_audit_write_error, :fail_writes).new(true, [], false, false) }
  let(:user) { OperationHelpers::User.new(12) }
  let(:subscriptions) { [] }

  def install_standard_audit
    rows = self.rows
    config = audit_config
    audit = Module.new do
      define_singleton_method(:config) { config }
      define_singleton_method(:record) do |event, actor: nil, metadata: {}, **|
        raise IOError, "disk full" if config.fail_writes

        rows << { event: event, actor: actor, metadata: metadata, via: :direct }
      end
    end
    operation = Module.new do
      def self.included(base)
        base.extend(Module.new do
          attr_reader :declared

          def audits(*actions)
            @declared = actions.flatten.map(&:to_s)
          end
        end)
      end

      private

      def audit!(action, **attributes)
        raise ::StandardAudit::Operation::DeclarationError, "undeclared #{action}" unless self.class.declared.include?(action)

        ::StandardAudit.record(action, **attributes)
      rescue ::StandardAudit::Operation::DeclarationError
        raise
      rescue StandardError
        raise if ::StandardAudit.config.raise_on_audit_write_error
      end
    end
    operation.const_set(:DeclarationError, Class.new(StandardError))
    audit.const_set(:Operation, operation)
    stub_const("StandardAudit", audit)
    config.subscriptions.each do |pattern|
      subscriptions << ActiveSupport::Notifications.subscribe(pattern) do |name, *, payload|
        rows << { event: name, actor: payload[:actor], metadata: payload.except(:actor), via: :notification }
      end
    end
  end

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
    StandardFlags.config.authorize = ->(*) { true }
  end

  after do
    subscriptions.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
    described_class.reset!
  end

  def ramp
    StandardFlags::Operations::Ramp.call(:new_checkout, bps: 500, actor: user, reason: "1% canary")
  end

  it "writes one row through StandardAudit::Operation" do
    install_standard_audit
    expect(ramp).to be_success
    expect(rows.size).to eq(1)
    expect(rows.first).to include(event: "standard_flags.flag.ramped", actor: user, via: :direct)
    expect(rows.first[:metadata]).to include(actor_label: "OperationHelpers::User:12", reason: "1% canary", key: "new_checkout", revision: 1)
    expect(StandardFlags::Operations::AuditWriter.declared).to eq(StandardFlags::Events.auditable)
  end

  it "records the full rule state before and after, not the actor record" do
    install_standard_audit
    ramp
    metadata = rows.first[:metadata]
    expect(metadata[:before]).to include(status: "draft", percentage_bps: nil, lock_version: 0)
    expect(metadata[:after]).to include(percentage_bps: 500, lock_version: 1)
    expect(metadata).not_to have_key(:actor)
  end

  it "records counts, never unit keys, for membership changes" do
    install_standard_audit
    StandardFlags::Operations::AddMembers.call(:new_checkout, keys: %w[acct-7731 acct-7732], actor: user, reason: "pilot")
    StandardFlags::Operations::RemoveMembers.call(:new_checkout, keys: %w[acct-7731], actor: user, reason: "left")
    expect(rows.map { |r| r[:event] }).to eq(%w[standard_flags.flag.members_added standard_flags.flag.members_removed])
    expect(rows.first[:metadata]).to include(unit: "account", value: "on", requested: 2, added: 2, updated: 0)
    expect(rows.last[:metadata]).to include(requested: 1, removed: 1)
    expect_no_unit_keys(rows)
  end

  it "leaves the row to standard_audit's subscriber when the app subscribes to the event" do
    audit_config.subscriptions = StandardFlags::Events.auditable
    install_standard_audit
    expect(ramp).to be_success
    expect(rows.map { |r| [ r[:event], r[:via] ] }).to eq([ [ "standard_flags.flag.ramped", :notification ] ])
    expect(rows.first[:actor]).to eq(user)
  end

  it "matches Regexp subscriptions too" do
    audit_config.subscriptions = [ /\Astandard_flags\./ ]
    install_standard_audit
    ramp
    expect(rows.map { |r| r[:via] }).to eq([ :notification ])
  end

  it "writes nothing when standard_audit is disabled" do
    audit_config.enabled = false
    install_standard_audit
    expect(ramp).to be_success
    expect(rows).to be_empty
  end

  it "passes no actor record for a system actor" do
    install_standard_audit
    StandardFlags::Operations::Pause.call(:new_checkout, actor: StandardFlags::Actor.system("guard"), reason: "x")
    StandardFlags::Operations::Ramp.call(:new_checkout, bps: 1, actor: StandardFlags::Actor.system("guard"), reason: "x")
    expect(rows.last).to include(actor: nil)
    expect(rows.last[:metadata]).to include(actor_label: "system:guard")
  end

  it "fails and rolls back when the app makes audit writes fatal" do
    audit_config.fail_writes = true
    audit_config.raise_on_audit_write_error = true
    install_standard_audit
    result = ramp
    expect(result).to have_attributes(code: :audit_failed, errors: [ include("IOError") ])
    expect([ store.revision, store.rule(:new_checkout) ]).to eq([ 0, nil ])
  end

  it "carries on when audit writes aren't fatal (standard_audit reports them)" do
    audit_config.fail_writes = true
    install_standard_audit
    expect(ramp).to be_success
  end

  context "with standard_audit subscribed and a subscriber that raises" do
    before do
      audit_config.subscriptions = StandardFlags::Events.auditable
      install_standard_audit
      subscriptions << ActiveSupport::Notifications.subscribe("standard_flags.flag.ramped") { raise IOError, "disk full" }
    end

    it "fails and rolls back when a subscriber's error makes audit writes fatal" do
      audit_config.raise_on_audit_write_error = true
      expect(ramp).to have_attributes(code: :audit_failed, errors: [ "the audit row could not be written (IOError); nothing was changed" ])
      expect([ store.revision, store.rule(:new_checkout) ]).to eq([ 0, nil ])
    end

    it "keeps the change and reports the lost row when audit writes aren't fatal" do
      result = nil
      errors = collect_errors { result = ramp }
      expect(result).to be_success
      expect(store.rule(:new_checkout).percentage_bps).to eq(500)
      expect(errors.reports.map { |r| r[:error].message })
        .to eq([ "the audit row for standard_flags.flag.ramped was not written (IOError); the change was kept" ])
    end
  end

  it "publishes the event once, inside the write, when standard_audit subscribes to it; the summary after" do
    audit_config.subscriptions = StandardFlags::Events.auditable
    install_standard_audit
    locked = []
    lock = store.instance_variable_get(:@mutex)
    handle = ActiveSupport::Notifications.subscribe(/\Astandard_flags\.flag\.|\Achange\.standard_flags\z/) { |name, *| locked << [ name, lock.mon_locked? ] }
    ramp
    expect(locked).to eq([ [ "standard_flags.flag.ramped", true ], [ "change.standard_flags", false ] ])
  ensure
    ActiveSupport::Notifications.unsubscribe(handle)
  end

  it "lets standard_audit's declaration check propagate" do
    install_standard_audit
    described_class.writer.audits("something.else")
    expect { ramp }.to raise_error(StandardAudit::Operation::DeclarationError, /undeclared standard_flags.flag.ramped/)
    expect(store.revision).to eq(0)
  end

  it "only publishes notifications without standard_audit" do
    events = events_during { ramp }
    expect(events.map(&:first)).to eq(%w[standard_flags.flag.ramped change.standard_flags])
    expect(StandardFlags::Operations.const_defined?(:AuditWriter, false)).to be(false)
  end

  describe "a reveal of unit keys (record_read)" do
    def payload
      { actor: user, actor_label: "OperationHelpers::User:12", reason: "support", key: :new_checkout, revealed: 2, total: 2 }
    end

    def reveal
      store.put_rule(:new_checkout, status: :running)
      store.add_member(rule: :new_checkout, unit: :account, unit_key: "acct-7731", value: true)
      StandardFlags::MCP.tool("list_members").call({ "key" => "new_checkout", "reveal" => true, "reason" => "support" }, actor: user)
    end

    it "writes one row through StandardAudit::Operation, and publishes the event" do
      install_standard_audit
      events = events_during { described_class.record_read(StandardFlags::Events::MEMBERS_REVEALED, payload) }
      expect(rows).to eq([ { event: "standard_flags.members.revealed", actor: user, metadata: payload.except(:actor), via: :direct } ])
      expect(events.map(&:first)).to eq([ "standard_flags.members.revealed" ])
    end

    it "leaves the row to standard_audit's subscriber when the app subscribes" do
      audit_config.subscriptions = StandardFlags::Events.auditable
      install_standard_audit
      expect(reveal["revealed"]).to be(true)
      expect(rows.map { |r| [ r[:event], r[:via] ] }).to eq([ [ "standard_flags.members.revealed", :notification ] ])
      expect_no_unit_keys(rows)
    end

    it "refuses the reveal when the row can't be written and the app makes that fatal" do
      audit_config.fail_writes = true
      audit_config.raise_on_audit_write_error = true
      install_standard_audit
      result = reveal
      expect(result["error"]).to include("code" => "audit_failed")
      expect_no_unit_keys(result)
    end

    context "when raise_on_audit_write_error is set (fail closed)" do
      before { audit_config.raise_on_audit_write_error = true }

      def found_log(found)
        Class.new do
          define_singleton_method(:where) { |*| self }
          define_singleton_method(:exists?) { found }
        end
      end

      it "writes the row directly, with an audit_ref, and publishes the event once" do
        install_standard_audit
        events = events_during { expect(reveal["revealed"]).to be(true) }
        expect(rows.map { |r| [ r[:event], r[:via] ] }).to eq([ [ "standard_flags.members.revealed", :direct ] ])
        expect(rows.first[:metadata][:audit_ref]).to match(/\A\h{8}-\h{4}-/)
        expect(events.map(&:first)).to eq([ "standard_flags.members.revealed" ])
      end

      it "reveals once the row is read back, and refuses when it isn't" do
        install_standard_audit
        stub_const("StandardAudit::AuditLog", found_log(true))
        expect(reveal["revealed"]).to be(true)
        stub_const("StandardAudit::AuditLog", found_log(false))
        expect(reveal["error"]).to include("code" => "audit_failed", "message" => include("not found after the write"))
      end

      it "refuses while standard_audit writes rows from a job, which can't be confirmed" do
        audit_config.define_singleton_method(:async) { true }
        install_standard_audit
        expect(reveal["error"]).to eq("code" => "audit_failed", "message" => "standard_audit writes audit rows from a job " \
                                                                             "(config.async), so this one can't be confirmed; nothing was revealed")
        expect(rows).to be_empty
      end

      it "still audits a probe with runtime rules off, outside any store write" do
        install_standard_audit
        StandardFlags.config.runtime_rules = false
        StandardFlags.config.runtime_store = nil
        result = StandardFlags::MCP.tool("get_flag").call({ "key" => "new_checkout", "unit_key" => "acct-1", "reason" => "x" }, actor: user)
        expect(result["evaluation"]).to include("unit_key" => "•••t-1")
        expect(rows.map { |r| r[:event] }).to eq([ "standard_flags.flag.probed" ])
      end

      it "lets standard_audit's declaration check propagate" do
        install_standard_audit
        described_class.writer.audits("something.else")
        expect { described_class.record_read(StandardFlags::Events::MEMBERS_REVEALED, payload) }
          .to raise_error(StandardAudit::Operation::DeclarationError)
      end
    end

    context "with standard_audit subscribed and a subscriber that raises" do
      before do
        audit_config.subscriptions = StandardFlags::Events.auditable
        install_standard_audit
        subscriptions << ActiveSupport::Notifications.subscribe("standard_flags.members.revealed") { raise IOError, "disk full" }
      end

      it "refuses the reveal when that is fatal" do
        audit_config.raise_on_audit_write_error = true
        expect(reveal["error"]).to eq("code" => "audit_failed", "message" => "the audit row could not be written (IOError); nothing was revealed")
      end

      it "reveals and reports the lost row otherwise" do
        result = nil
        errors = collect_errors { result = reveal }
        expect(result["revealed"]).to be(true)
        expect(errors.reports.map { |r| r[:error].message }).to eq([ "the audit row for standard_flags.members.revealed was not written (IOError)" ])
      end
    end
  end

  it "lists every event as auditable" do
    expect(StandardFlags::Events.auditable - [ "standard_flags.members.revealed" ])
      .to all(start_with("standard_flags.flag.").or(start_with("standard_flags.cohort.")))
    expect(StandardFlags::Events.auditable).to include("standard_flags.flag.restored", "standard_flags.cohort.restored",
                                                       "standard_flags.flag.probed")
    expect(StandardFlags::Events.auditable.size).to eq(19)
    expect(StandardFlags::Events.auditable).to be_frozen
  end
end
