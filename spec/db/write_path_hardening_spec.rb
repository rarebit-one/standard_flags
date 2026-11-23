require "spec_helper"

# Write-path guarantees on Postgres: what commits, what waits on what, and
# what reaches SQL text.
RSpec.describe "write path hardening on Postgres", :db, registry: OperationHelpers::REGISTRY do
  let(:models) { StandardFlags::Runtime::Models }
  let(:ops) { OperationHelpers::Ops }
  let(:time) { [ 0.0 ] }
  let(:connection) { ActiveRecord::Base.connection }
  let(:audit_handles) { [] }

  before do
    require "standard_flags/runtime/active_record_store"
    StandardFlags.config.runtime_rules = true
    StandardFlags::Runtime.clock = -> { time.first }
  end

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  def unit_of_work(&)
    Rails.application.executor.wrap(&)
  end

  def state_revision
    models::State.pick(:revision)
  end

  # Holds each write made on a thread with Thread.current[:hold] set, just
  # before it moves the revision (after its rows are written and locked).
  def hold_writes(seconds, gate)
    allow(StandardFlags::Runtime).to receive(:bump_revision!).and_wrap_original do |original, tx|
      if (hold = Thread.current[:hold])
        gate << :held
        sleep hold.equal?(true) ? seconds : hold
      end
      original.call(tx)
    end
  end

  # standard_audit, as far as the gem sees it: config, plus a subscriber on
  # every auditable event that runs `write` inside the operation.
  def subscribe_standard_audit(raise_on_audit_write_error: false, &write)
    config = Struct.new(:enabled, :subscriptions, :raise_on_audit_write_error)
                   .new(true, StandardFlags::Events.auditable, raise_on_audit_write_error)
    audit = Module.new { define_singleton_method(:config) { config } }
    audit.const_set(:Operation, Module.new)
    stub_const("StandardAudit", audit)
    audit_handles << ActiveSupport::Notifications.subscribe(/\Astandard_flags\./) do |name, *|
      write.call(name)
    rescue StandardError
      nil # as its Subscriber#handle_event does, after reporting
    end
  end

  after { audit_handles.each { |h| ActiveSupport::Notifications.unsubscribe(h) } }

  # Memberships of `rule_id` that expired 100 days ago.
  def expired_members!(rule_id, keys)
    old = Time.now.utc - (100 * 86_400)
    models::Membership.insert_all(keys.map { |k| { rule_id: rule_id, unit: "account", unit_key: k, value: "on", expires_at: old, created_at: old, updated_at: old } })
    models::Rule.where(id: rule_id).update_all(member_count: keys.size)
  end

  # Runs the block on a thread whose write is held (see hold_writes), and
  # returns the thread once the write is holding.
  def held_write(gate, &block)
    thread = in_thread do
      Thread.current[:hold] = true
      block.call
    end
    gate.pop(timeout: 10)
    thread
  end

  # Members in a cohort, a rule and a phone-keyed rule, all running.
  def members_everywhere!
    op!(ops::CreateCohort, "staff", unit: :account)
    op!(ops::AddMembers, "cohort:staff", keys: %w[acct-7731 acct-7732])
    op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
    op!(ops::AddMembers, :phone_login, keys: [ "+6591234567" ], expires_at: Time.now.utc + 60)
    op!(ops::AddMembers, :new_checkout, keys: %w[acct-7732], value: false)
    op!(ops::Start, :new_checkout)
    op!(ops::Start, :phone_login)
  end

  describe "an operation succeeds only when its write commits" do
    it "keeps the change when standard_audit's subscriber swallows a failed audit insert" do
      subscribe_standard_audit { connection.execute("INSERT INTO audit_logs_missing VALUES (1)") }
      result = nil
      errors = collect_errors { result = op(ops::Ramp, :new_checkout, bps: 500) }

      expect(result).to be_success, -> { result.inspect }
      expect([ models::Rule.pick(:percentage_bps), state_revision ]).to eq([ 500, result.value[:store_revision] ])
      expect(errors.reports.map { |r| r[:error].message })
        .to eq([ "the audit row for standard_flags.flag.ramped was not written (ActiveRecord::StatementInvalid); the change was kept" ])
    end

    it "fails with :audit_failed and changes nothing when raise_on_audit_write_error is set (subscriber path)" do
      subscribe_standard_audit(raise_on_audit_write_error: true) { connection.execute("INSERT INTO audit_logs_missing VALUES (1)") }
      result = op(ops::Ramp, :new_checkout, bps: 500)
      expect(result.code).to eq(:audit_failed)
      expect([ models::Rule.count, state_revision ]).to eq([ 0, 0 ])
    end

    it "writes the audit row in the operation's transaction on the subscriber path" do
      connection.execute("CREATE TEMPORARY TABLE spec_audit_rows (event text)")
      subscribe_standard_audit { |name| connection.exec_query("INSERT INTO spec_audit_rows VALUES ($1)", "spec", [ name ]) }
      op!(ops::Ramp, :new_checkout, bps: 500)
      expect(op(ops::Ramp, :new_checkout, bps: 50, expected_revision: 99).code).to eq(:stale_revision)
      expect(connection.select_values("SELECT event FROM spec_audit_rows")).to eq([ "standard_flags.flag.ramped" ])
    ensure
      connection.execute("DROP TABLE IF EXISTS spec_audit_rows")
    end

    context "with the direct path (audit!), which swallows a failed write by default" do
      # Like audit! -> AuditLog#save! (a nested, joinable transaction) with
      # raise_on_audit_write_error off: the failed insert is swallowed.
      before do
        stub_const("SwallowingAuditWriter", Class.new do
          def write(*, **)
            ActiveRecord::Base.transaction { ActiveRecord::Base.connection.execute("INSERT INTO audit_logs_missing VALUES (1)") }
          rescue StandardError
            nil
          end
        end)
        allow(StandardFlags::Operations::Audit).to receive_messages(direct?: true, writer: SwallowingAuditWriter)
      end

      it "keeps the change and reports the missing row" do
        result = nil
        errors = collect_errors { result = op(ops::Ramp, :new_checkout, bps: 500) }
        expect(result).to be_success
        expect([ models::Rule.count, state_revision ]).to eq([ 1, result.value[:store_revision] ])
        expect(errors.reports.size).to eq(1)
      end

      it "fails with :audit_failed when raise_on_audit_write_error is set" do
        allow(StandardFlags::Operations::Audit).to receive(:raise_on_write_error?).and_return(true)
        expect(op(ops::Ramp, :new_checkout, bps: 500).code).to eq(:audit_failed)
        expect([ models::Rule.count, state_revision ]).to eq([ 0, 0 ])
      end
    end

    it "fails with :store_error when anything else swallowed an error that aborted the transaction" do
      allow(StandardFlags::Runtime::ActiveRecordStore::Transaction).to receive(:new).and_wrap_original do |new_transaction|
        new_transaction.call.tap do |tx|
          allow(tx).to receive(:bump_revision).and_wrap_original do |original|
            original.call.tap { ActiveRecord::Base.connection.execute("SELECT * FROM missing_table") rescue nil } # rubocop:disable Style/RescueModifier
          end
        end
      end
      result = nil
      events = events_during { result = op(ops::Ramp, :new_checkout, bps: 500) }
      expect(result.code).to eq(:store_error)
      expect([ models::Rule.count, state_revision, events ]).to eq([ 0, 0, [] ])
    end
  end

  describe "a missing standard_flags_state row (a database loaded from schema.rb)" do
    before { models::State.delete_all }

    it "is created by the first write, which moves the revision so every process reloads" do
      StandardFlags.evaluate(:new_checkout, for: for_account("a1")) # loaded with no revision
      ramped = op!(ops::Ramp, :new_checkout, bps: 10_000)
      op!(ops::Start, :new_checkout)

      expect(ramped.value[:store_revision]).to be_positive
      expect(models::State.count).to eq(1)
      expect(StandardFlags.evaluate(:new_checkout, for: for_account("a1"))).to have_attributes(value: true, rule_id: "percentage")
    end

    it "is created by a cohort operation's revision check" do
      expect(op!(ops::CreateCohort, "beta", unit: :account).value[:store_revision]).to eq(state_revision)
      expect(models::State.count).to eq(1)
    end

    it "is created once when writers race to create it" do
      flags = %i[new_checkout strict_gates global_banner home_hero] # the pool has 5 connections
      arrived = Queue.new
      go = Queue.new
      allow(StandardFlags::Runtime).to receive(:bump_revision!).and_wrap_original do |original, tx|
        arrived << true
        go.pop(timeout: 10)
        original.call(tx)
      end
      threads = flags.map { |key| in_thread { op(ops::SetValue, key, value: nil) } }
      flags.size.times { arrived.pop(timeout: 10) }
      flags.size.times { go << true }
      results = threads.map(&:value)

      expect(results).to all(be_success)
      revisions = results.map { |r| r.value[:store_revision] }
      expect([ models::State.count, revisions.uniq.size, state_revision ]).to eq([ 1, flags.size, revisions.max ])
    end

    it "reads as no revision, so the rules reload at every check and nothing stale is served" do
      models::Rule.create!(key: "new_checkout", salt: "s", status: "running", fallthrough_value: "off")
      expect(StandardFlags::Runtime.store.revision).to be_nil
      expect(StandardFlags.on?(:new_checkout, for: for_account("a1"))).to be(false)
      models::Rule.where(key: "new_checkout").update_all(fallthrough_value: "on")
      time[0] += 5
      expect(StandardFlags.on?(:new_checkout, for: for_account("a1"))).to be(true)
    end

    it "is a health check warning" do
      expect(StandardFlags::Runtime.store.warnings).to include(a_string_starting_with("standard_flags_state has no row"))
      op!(ops::SetValue, :global_banner, value: true)
      expect(StandardFlags::Runtime.store.warnings).to eq([])
    end
  end

  describe "last_evaluated_at" do
    before do
      op!(ops::SetValue, :strict_gates, value: :sensor)
      op!(ops::Start, :strict_gates)
    end

    it "is never written during an evaluation, only when the unit of work ends" do
      unit_of_work { StandardFlags.evaluate(:strict_gates, for: for_account("a1")) }
      time[0] += 3_601
      during = nil
      after = DatabaseHelpers.queries do
        unit_of_work { during = DatabaseHelpers.queries { StandardFlags.evaluate(:strict_gates, for: for_account("a1")) } }
      end
      expect(during.grep(/UPDATE/)).to eq([])
      expect(after.grep(/\AUPDATE "standard_flags_rules" SET last_evaluated_at/).size).to eq(1)
    end

    it "never waits on a write that holds the rule row" do
      unit_of_work { StandardFlags.evaluate(:strict_gates, for: for_account("a1")) }
      time[0] += 3_601
      locked = Queue.new
      holder = in_thread { models::Record.transaction { models::Rule.lock.find_by!(key: "strict_gates") && locked << true && sleep(1.5) } }
      locked.pop(timeout: 10) # a slow write holds the row for 1.5 s

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      in_thread { unit_of_work { StandardFlags.evaluate(:strict_gates, for: for_account("a1")) } }.join
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      holder.join
      expect(took).to be < 0.5
    end

    it "leaves lock_version and updated_at alone, so a rule nobody changed keeps its revision" do
      seen = models::Rule.where(key: "strict_gates").pick(:lock_version, :updated_at)
      unit_of_work { StandardFlags.evaluate(:strict_gates, for: for_account("a1")) }
      time[0] += 3_601
      unit_of_work { StandardFlags.evaluate(:strict_gates, for: for_account("a1")) }

      expect(models::Rule.where(key: "strict_gates").pick(:lock_version, :updated_at)).to eq(seen)
      expect(models::Rule.where(key: "strict_gates").pick(:last_evaluated_at)).not_to be_nil
      expect(op(ops::SetValue, :strict_gates, value: :on, expected_revision: seen.first)).to be_success
    end
  end

  it "keeps member_count right when purge runs while AddMembers is in flight" do
    op!(ops::SetValue, :strict_gates, value: :sensor)
    op!(ops::Start, :strict_gates)
    rule_id = models::Rule.find_by!(key: "strict_gates").id
    expired_members!(rule_id, %w[x1 x2])

    gate = Queue.new
    hold_writes(1.0, gate)
    adding = held_write(gate) { op(ops::AddMembers, :strict_gates, keys: [ "acct-new" ], value: :on) }
    purging = in_thread { StandardFlags::Runtime.purge! }
    added = adding.value
    counts = purging.value

    live = models::Membership.where(rule_id: rule_id, removed_at: nil).count
    expect([ added.success?, counts, live, models::Rule.where(id: rule_id).pick(:member_count) ]).to eq([ true, { removed: 0, expired: 2 }, 1, 1 ])
    time[0] += 3_600
    expect(StandardFlags.evaluate(:strict_gates, for: for_account("acct-new"))).to have_attributes(value: :on, rule_id: "allow")
  end

  it "lets purge and AddMembers re-adding an expired member both finish" do
    op!(ops::SetValue, :strict_gates, value: :sensor)
    rule_id = models::Rule.find_by!(key: "strict_gates").id
    expired_members!(rule_id, %w[x1])

    gate = Queue.new
    hold_writes(0.5, gate)
    adding = held_write(gate) { op(ops::AddMembers, :strict_gates, keys: [ "x1" ], value: :on) }
    purging = in_thread { StandardFlags::Runtime.purge! }

    expect([ adding.value.success?, purging.value ]).to eq([ true, { removed: 0, expired: 0 } ])
    expect(models::Membership.where(rule_id: rule_id).pluck(:unit_key, :expires_at)).to eq([ [ "x1", nil ] ])
  end

  it "fails the second of two concurrent CreateCohort calls on one key with :already_exists" do
    gate = Queue.new
    hold_writes(0.5, gate)
    events = []
    handle = ActiveSupport::Notifications.subscribe("standard_flags.cohort.created") { |*, payload| events << payload[:after][:unit] }
    first = held_write(gate) { op(ops::CreateCohort, "beta", unit: :account, name: "A") }
    second = in_thread { op(ops::CreateCohort, "beta", unit: :phone, name: "B") }

    expect([ first.value.success?, second.value.code ]).to eq([ true, :already_exists ])
    expect([ models::Cohort.pluck(:key, :unit, :name), events ]).to eq([ [ %w[beta account A] ], %w[account] ])
  ensure
    ActiveSupport::Notifications.unsubscribe(handle)
  end

  describe "side effects" do
    it "notifies after the commit, when the state row is free again" do
      free = []
      StandardFlags.config.add_notifier(lambda do |name, _payload|
        next unless name == "change.standard_flags"

        free << in_thread do
          models::Record.transaction { connection.select_value("SELECT revision FROM standard_flags_state FOR UPDATE NOWAIT") }
          true
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::StatementInvalid
          false
        end.value
      end)
      StandardFlags.subscribers.setup!
      op!(ops::Ramp, :new_checkout, bps: 500)
      expect(free).to eq([ true ])
    ensure
      StandardFlags.subscribers.teardown!
    end

    it "publishes nothing, and expires nothing, for a host transaction that rolls back" do
      StandardFlags.config.refresh_interval = 3_600
      op!(ops::SetValue, :global_banner, value: false)
      op!(ops::Start, :global_banner)
      expect(StandardFlags.on?(:global_banner)).to be(false)
      events = events_during do
        models::Record.transaction do
          op!(ops::SetValue, :global_banner, value: true)
          raise ActiveRecord::Rollback
        end
      end
      expect(events).to eq([])
      expect(StandardFlags.on?(:global_banner)).to be(false)
    end

    it "publishes and expires when the host transaction commits" do
      StandardFlags.config.refresh_interval = 3_600
      op!(ops::SetValue, :global_banner, value: false)
      op!(ops::Start, :global_banner)
      expect(StandardFlags.on?(:global_banner)).to be(false)
      events = []
      models::Record.transaction do
        events = events_during { op!(ops::SetValue, :global_banner, value: true) }
        expect(events).to eq([])
        events = events_during { connection.execute("SELECT 1") }
      end
      expect(StandardFlags.on?(:global_banner)).to be(true)
    end
  end

  it "never puts a unit key into SQL text: AddMembers, RemoveMembers, purge, evaluation and preload" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    members_everywhere!
    unit_of_work do
      StandardFlags.preload(:account, %w[acct-7731 acct-7732])
      StandardFlags.evaluate(:new_checkout, for: for_account("acct-7731"))
    end
    StandardFlags.evaluate(:phone_login, for: StandardFlags::Context.new(actors: { phone: "+6591234567" }))
    op!(ops::RemoveMembers, "cohort:staff", keys: %w[acct-7731])
    models::Membership.update_all(removed_at: Time.now.utc - (100 * 86_400))
    StandardFlags::Runtime.purge!

    expect(statements.grep(/standard_flags_memberships/).size).to be >= 8
    OperationHelpers::SECRET_KEYS.each { |key| expect(statements.grep(/#{Regexp.escape(key)}/)).to eq([]) }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "lock order" do
    it "locks a rule's cohorts in one statement, by id, whatever the attachment order" do
      %w[gamma alpha beta].each { |key| op!(ops::CreateCohort, key, unit: :account) }
      %w[beta gamma alpha].each { |key| op!(ops::AttachCohort, :new_checkout, cohort: key, value: true) }
      op!(ops::SetValue, :new_checkout, value: false)

      locks = DatabaseHelpers.queries { op!(ops::Start, :new_checkout) }.grep(/FOR UPDATE/)
      expect(locks.size).to eq(2) # the rule, then its cohorts
      expect(locks.first).to include('FROM "standard_flags_rules"')
      expect(locks.last).to include('FROM "standard_flags_cohorts"', 'ORDER BY "standard_flags_cohorts"."id"')
    end

    it "lets Starts whose rules attach the same cohorts in opposite orders run together" do
      %w[x y].each { |key| op!(ops::CreateCohort, key, unit: :account) }
      { strict_gates: %w[x y], new_checkout: %w[y x] }.each do |flag, keys|
        keys.each { |key| op!(ops::AttachCohort, flag, cohort: key, value: :on) }
      end
      gate = Queue.new
      hold_writes(0.3, gate)
      results = %i[strict_gates new_checkout].map { |flag| held_write(gate) { op(ops::Start, flag) } }.map(&:value)
      expect(results.map(&:code)).to eq([ nil, nil ])
    end
  end
end
