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

  it "lists every event as auditable" do
    expect(StandardFlags::Events.auditable).to all(start_with("standard_flags.flag.").or(start_with("standard_flags.cohort.")))
    expect(StandardFlags::Events.auditable.size).to eq(15)
    expect(StandardFlags::Events.auditable).to be_frozen
  end
end
