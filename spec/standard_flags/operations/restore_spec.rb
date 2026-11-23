require "spec_helper"

RSpec.describe StandardFlags::Operations::Restore, registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:trail) { RestoreHelpers::RecordingTrail.new }
  let(:ops) { OperationHelpers::Ops }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
    trail
  end

  after { trail.stop }

  def restore(at, **options)
    described_class.call(at: at, reason: "bad change", trail: trail, **options)
  end

  def state(key)
    store.rule(key).audit_state.except(:lock_version, :member_count)
  end

  def member_keys(**owner)
    store.members(**owner).memberships.map(&:unit_key).sort
  end

  def entry(result, target)
    result.value[:entries].find { |e| e[:target] == target.to_s }
  end

  def statuses(result)
    result.value[:entries].map { |e| e[:status] }
  end

  describe "a round trip" do
    before do
      op!(ops::CreateCohort, "staff", unit: :account)
      op!(ops::AddMembers, "cohort:staff", keys: %w[acct-7731])
      op!(ops::Ramp, :new_checkout, bps: 500)
      op!(ops::SetConditions, :new_checkout, platforms: %w[ios])
      op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731 acct-7732])
      op!(ops::AddMembers, :new_checkout, keys: %w[+6591234567], value: false)
      op!(ops::Start, :new_checkout)
      op!(ops::SetVariants, :home_hero, weights: { control: 5_000, savings: 5_000 })
      op!(ops::Start, :home_hero)
    end

    def evaluations
      %w[acct-7731 acct-7733 +6591234567].map { |id| StandardFlags.evaluate(:new_checkout, for: for_account(id)).to_h }
    end

    context "with changes made since" do
      let(:at) { checkpoint }
      let(:first) do
        { new_checkout: state(:new_checkout), home_hero: state(:home_hero), members: member_keys(rule: :new_checkout),
          cohort: member_keys(cohort: :staff), evaluations: evaluations }
      end

      before do
        at
        first
        op!(ops::Pause, :new_checkout)
        op!(ops::Ramp, :new_checkout, bps: 9_000)
        op!(ops::SetConditions, :new_checkout)
        op!(ops::DetachCohort, :new_checkout, cohort: "staff")
        op!(ops::SetValue, :new_checkout, value: true)
        op!(ops::RemoveMembers, :new_checkout, keys: %w[acct-7731 +6591234567])
        op!(ops::AddMembers, :new_checkout, keys: %w[acct-7734])
        op!(ops::AddMembers, :new_checkout, keys: %w[acct-7732], value: false)
        op!(ops::AddMembers, "cohort:staff", keys: %w[acct-7735])
        op!(ops::SetVariants, :home_hero, weights: { control: 1_000, savings: 9_000 })
        op!(ops::Ramp, :strict_gates, bps: 100, value: :on)
        op!(ops::Start, :strict_gates)
      end

      it "plans each change, member changes as counts, without applying them" do
        plan = restore(at)
        expect([ plan.success?, plan.value[:applied], state(:new_checkout) == first[:new_checkout] ]).to eq([ true, false, false ])
        expect(entry(plan, :new_checkout)).to include(status: "planned", changes: [
          "status paused → running", "conditions {} → {\"platforms\":[\"ios\"]}", "percentage 9000 bps → 500 bps",
          "fallthrough on → -", "attach cohort staff → on", "members −1 (account)", "members +2 (account → on)",
          "members +1 (account → off)"
        ])
        expect(entry(plan, :home_hero)[:changes]).to eq([ "variants {\"control\":1000,\"savings\":9000} → {\"control\":5000,\"savings\":5000}" ])
        expect([ plan.value[:entries].first, plan.value[:entries].last ]).to eq([
          { target: "cohort:staff", status: "planned", changes: [ "members −1 (account)" ], notes: [] },
          { target: "strict_gates", status: "skipped", changes: [], notes: [ "no audit history at T; left unchanged" ] }
        ])
      end

      it "applies each target in one write: one revision bump and one restored row each" do
        revision = store.revision
        applied = nil
        events = events_during { applied = restore(at, apply: true) }
        expect([ applied.success?, statuses(applied) ]).to eq([ true, %w[applied applied applied skipped] ])
        expect(store.revision - revision).to eq(3)
        expect(events.map(&:first).grep(/\Astandard_flags\./))
          .to eq(%w[standard_flags.cohort.restored standard_flags.flag.restored standard_flags.flag.restored])
        restored = events.find { |name, payload| name == "standard_flags.flag.restored" && payload[:key] == "new_checkout" }.last
        expect(restored).to include(restored_to: at.utc.iso8601, members: { removed: 1, added: 2, updated: 1 },
                                    before: include(status: "paused"), after: include(status: "running", percentage_bps: 500))
        expect(statuses(restore(at)).uniq).to eq(%w[unchanged skipped])
      end

      it "puts rules, members and what they serve back as they were" do
        restore(at, apply: true)
        expect([ state(:new_checkout), state(:home_hero) ]).to eq([ first[:new_checkout], first[:home_hero] ])
        expect([ member_keys(rule: :new_checkout), member_keys(cohort: :staff) ]).to eq([ first[:members], first[:cohort] ])
        expect(store.rule(:strict_gates).status).to eq("running") # no audit history at T: left alone
        expect(evaluations).to eq(first[:evaluations])
      end
    end

    it "writes no unit key into its result or the audit trail" do
      at = checkpoint
      op!(ops::RemoveMembers, :new_checkout, keys: OperationHelpers::SECRET_KEYS)
      result = nil
      events = events_during { result = restore(at, apply: true) }
      expect(result).to be_success
      expect(events.map(&:first)).to include("standard_flags.flag.restored")
      expect(events.filter_map { |_, payload| payload[:reason] }.uniq).to eq([ "restore to #{at.utc.iso8601}: bad change" ])
      expect(events.filter_map { |_, payload| payload[:actor_label] }.uniq).to eq([ "system:restore" ])
      expect_no_unit_keys(result, result.value, events, trail.rows)
    end

    it "restores only the keys asked for" do
      at = checkpoint
      op!(ops::Pause, :new_checkout)
      op!(ops::Pause, :home_hero)
      result = restore(at, keys: %w[home_hero], apply: true)
      expect(result.value[:entries].map { |e| e[:target] }).to eq(%w[home_hero])
      expect([ store.rule(:home_hero).status, store.rule(:new_checkout).status ]).to eq(%w[running paused])
    end

    it "changes nothing on a dry run" do
      at = checkpoint
      op!(ops::Pause, :new_checkout)
      revision = store.revision
      expect(statuses(restore(at))).to include("planned")
      expect([ store.revision, store.rule(:new_checkout).status ]).to eq([ revision, "paused" ])
    end
  end

  describe "refusals" do
    it "refuses a time older than the membership retention" do
      StandardFlags.config.membership_retention = 3_600
      result = restore(Time.now - 7_200)
      expect(result.code).to eq(:retention_exceeded)
      expect(result.errors.first).to include("older than config.membership_retention")
    end

    it "refuses a future time, a missing reason, a non-Time and runtime rules off" do
      expect(restore(Time.now + 60).code).to eq(:invalid)
      expect(described_class.call(at: Time.now, reason: " ", trail: trail).errors).to eq([ "a reason is required" ])
      expect(described_class.call(at: "yesterday", reason: "x", trail: trail).errors).to eq([ "at: must be a Time" ])
      StandardFlags.config.runtime_rules = false
      StandardFlags.config.runtime_store = nil
      expect(restore(Time.now - 1).code).to eq(:runtime_rules_off)
    end

    it "fails clearly without standard_audit" do
      result = described_class.call(at: Time.now - 1, reason: "x")
      expect(result.code).to eq(:audit_unavailable)
      expect(result.errors.first).to include("standard_audit is not loaded")
    end

    it "reports a store error" do
      allow(store).to receive(:load).and_raise(StandardFlags::Runtime::StoreError.new("rule load failed: IOError", cause_class: "IOError"))
      errors = []
      StandardFlags.config.error_reporter = ->(error, context) { errors << [ error.message, context ] }
      expect(restore(Time.now - 1).code).to eq(:store_error)
      expect(errors).to eq([ [ "rule load failed: IOError", { operation: "restore" } ] ])
    end
  end

  describe "what it skips" do
    it "skips a pinned flag, naming the variable" do
      op!(ops::Start, :new_checkout) if op(ops::Ramp, :new_checkout, bps: 500).success?
      at = checkpoint
      op!(ops::Pause, :new_checkout)
      StandardFlags.config.env_source = { "STANDARD_FLAGS_NEW_CHECKOUT" => "on" }
      result = restore(at, apply: true)
      expect(entry(result, :new_checkout)).to eq(target: "new_checkout", status: "skipped", changes: [],
                                                 notes: [ "pinned by STANDARD_FLAGS_NEW_CHECKOUT; skipped" ])
      expect(store.rule(:new_checkout).status).to eq("paused")
    end

    it "skips undeclared and tombstoned keys and cohorts that are gone" do
      result = restore(Time.now - 1, keys: %w[old_banner ghost_flag cohort:ghost])
      expect(result.value[:entries].map { |e| [ e[:target], e[:notes] ] })
        .to eq([ [ "cohort:ghost", [ "cohort does not exist now" ] ], [ "old_banner", [ "tombstoned flag" ] ], [ "ghost_flag", [ "undeclared flag" ] ] ])
    end

    it "notes what the operations can't do" do
      op!(ops::Ramp, :new_checkout, bps: 500)
      op!(ops::Start, :new_checkout)
      at = checkpoint
      op!(ops::Stop, :new_checkout, serve: true)
      notes = entry(restore(at), :new_checkout)
      expect(notes).to include(status: "unchanged", notes: [ "stopped now and running then; operations can't un-stop a rule" ])

      op!(ops::SetValue, :global_banner, value: true)
      at = checkpoint
      op!(ops::SetValue, :global_banner, value: false)
      op!(ops::Stop, :global_banner, serve: false)
      expect(entry(restore(at, keys: %w[global_banner]), :global_banner)[:notes]).to include(include("operations can't un-stop"))
    end

    # Audit rows go missing (the audit log's retention, auditing set up
    # after the rule, a lost write), so "no row at or before T" says nothing
    # about the rule then; only an audited state may drive a change.
    it "skips a flag with no audit history at T, whatever it is now, members included" do
      op!(ops::SetValue, :ai_assistant, value: false)
      op!(ops::Start, :ai_assistant) # a kill switch thrown before the audit window
      op!(ops::Stop, :new_checkout, serve: true)
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731])
      at = checkpoint
      pruned = Struct.new(:states) { def rule_states(_at) = states }.new({})
      result = described_class.call(at: at, reason: "undo a bad ramp elsewhere", trail: pruned, apply: true)

      expect(result).to be_success
      expect(result.value[:entries]).to eq(%w[ai_assistant new_checkout].map do |key|
        { target: key, status: "skipped", changes: [], notes: [ "no audit history at T; left unchanged" ] }
      end)
      expect([ store.rule(:ai_assistant).status, store.rule(:new_checkout).status ]).to eq(%w[running stopped])
      expect(member_keys(rule: :new_checkout)).to eq(%w[acct-7731])
      StandardFlags::Runtime.expire!
      expect(StandardFlags.evaluate(:ai_assistant, for: for_account("acct-1")).value).to be(false)
    end

    it "notes a percentage it can't clear, a draft left as is, and bucketing it can't change" do
      at = checkpoint
      store.put_rule(:new_checkout, status: :paused, percentage_bps: 100, salt: "other")
      trail.rows << [ at - 1, "standard_flags.flag.paused",
                      { "key" => "new_checkout", "after" => { "status" => "draft", "salt" => "s", "hash_version" => 2, "percentage_bps" => nil,
                                                              "rollout_value" => nil, "variant_weights" => {}, "fallthrough_value" => nil,
                                                              "stop_value" => nil, "conditions" => {}, "cohorts" => [] } } ]
      expect(entry(restore(at), :new_checkout)[:notes]).to eq(
        [ "bucketing (salt, hash version) differs and can't change; kept",
          "draft and paused both serve the code default; left paused",
          "no percentage then, 100 bps now; operations can't clear a percentage, so it was kept" ]
      )
    end
  end

  describe "status and cohorts" do
    it "stops a rule that was stopped then, and restores its stop value" do
      op!(ops::Stop, :new_checkout, serve: true)
      at = checkpoint
      op!(ops::Stop, :new_checkout, serve: false)
      result = restore(at, apply: true)
      expect(entry(result, :new_checkout)[:changes]).to eq([ "status stopped → stopped, serving on" ])
      expect(store.rule(:new_checkout).stop_value).to eq("on")

      op!(ops::Ramp, :home_hero, bps: 100, value: "savings")
      op!(ops::Stop, :home_hero, serve: "savings")
      at = checkpoint
      op!(ops::Ramp, :home_hero, bps: 200, value: "savings")
      expect(entry(restore(at), :home_hero)[:changes]).to eq([ "percentage 200 bps → savings → 100 bps → savings" ])
    end

    it "pauses a running rule that was paused, before changing its settings" do
      op!(ops::Ramp, :new_checkout, bps: 500)
      op!(ops::Start, :new_checkout)
      op!(ops::Pause, :new_checkout)
      at = checkpoint
      op!(ops::Start, :new_checkout)
      op!(ops::Ramp, :new_checkout, bps: 700)
      expect(entry(restore(at, apply: true), :new_checkout)[:changes]).to eq([ "status running → paused", "percentage 700 bps → 500 bps" ])
      expect(store.rule(:new_checkout)).to have_attributes(status: "paused", percentage_bps: 500)
    end

    it "puts cohorts back in their old order" do
      op!(ops::CreateCohort, "staff", unit: :account)
      op!(ops::CreateCohort, "beta", unit: :account)
      op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
      op!(ops::AttachCohort, :new_checkout, cohort: "beta", value: true)
      at = checkpoint
      op!(ops::DetachCohort, :new_checkout, cohort: "staff")
      result = restore(at, apply: true)
      expect(entry(result, :new_checkout)).to include(changes: [ "attach cohort staff → on" ], notes: [])
      expect(store.rule(:new_checkout).cohorts.map { |a| a["cohort"] }).to eq(%w[staff beta])

      at = checkpoint
      op!(ops::DetachCohort, :new_checkout, cohort: "staff")
      op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
      expect(entry(restore(at, apply: true), :new_checkout)[:changes]).to eq([ "cohort order beta, staff → staff, beta" ])
      expect(store.rule(:new_checkout).cohorts.map { |a| a["cohort"] }).to eq(%w[staff beta])
    end

    it "notes members that expired since, and keeps an expiry that is still ahead" do
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731], expires_at: Time.now + 0.05)
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7732], expires_at: Time.now + 3_600)
      at = checkpoint
      op!(ops::RemoveMembers, :new_checkout, keys: %w[acct-7731 acct-7732])
      sleep 0.06
      result = restore(at, apply: true)
      expect(entry(result, :new_checkout)).to include(changes: [ "members +1 (account → on)" ],
                                                      notes: [ "1 member(s) expired since then; not restored" ])
      expect(store.members(rule: :new_checkout).memberships.map(&:unit_key)).to eq(%w[acct-7732])
    end

    it "changes more members than the per-operation limit in one write, in chunks of it" do
      op!(ops::SetValue, :new_checkout, value: true)
      at = checkpoint
      op!(ops::AddMembers, :new_checkout, keys: %w[a1 a2 a3])
      StandardFlags.config.max_keys_per_operation = 2
      chunks = []
      allow(store).to receive(:tx_remove_members).and_wrap_original { |m, owner, **kw| chunks << kw[:unit_keys].size; m.call(owner, **kw) }
      revision = store.revision
      result = restore(at, apply: true)
      expect(entry(result, :new_checkout)).to include(status: "applied", changes: [ "members −3 (account)" ])
      expect([ chunks, member_keys(rule: :new_checkout), store.revision - revision ]).to eq([ [ 2, 1 ], [], 1 ])
    end

    # Removing before adding: at max_members, swapping one full set for
    # another must not need room for both.
    it "removes before it adds, so a full rule's members can be swapped" do
      StandardFlags.config.max_members = 3
      op!(ops::Ramp, :new_checkout, bps: 0)
      op!(ops::AddMembers, :new_checkout, keys: %w[a1 a2 a3])
      op!(ops::Start, :new_checkout)
      op!(ops::SetValue, :new_checkout, value: false)
      at = checkpoint
      op!(ops::RemoveMembers, :new_checkout, keys: %w[a1 a2 a3])
      op!(ops::AddMembers, :new_checkout, keys: %w[b1 b2 b3])
      result = restore(at, keys: %w[new_checkout], apply: true)
      expect(entry(result, :new_checkout)).to include(status: "applied", changes: [ "members −3 (account)", "members +3 (account → on)" ])
      expect(member_keys(rule: :new_checkout)).to eq(%w[a1 a2 a3])
    end

    it "restores cohort members before the flags that attach the cohort" do
      op!(ops::CreateCohort, "staff", unit: :account)
      op!(ops::AddMembers, "cohort:staff", keys: %w[acct-7731])
      op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
      op!(ops::Start, :new_checkout)
      at = checkpoint
      op!(ops::Pause, :new_checkout)
      op!(ops::RemoveMembers, "cohort:staff", keys: %w[acct-7731])
      order = []
      allow(StandardFlags::Operations::RestoreTarget).to receive(:call).and_wrap_original do |original, target, **kwargs|
        order << [ target.to_s, member_keys(cohort: :staff) ]
        original.call(target, **kwargs)
      end
      restore(at, apply: true)
      expect(order).to eq([ [ "cohort:staff", [] ], [ "new_checkout", %w[acct-7731] ] ])
    end
  end

  it "creates a rule that is gone now again, with the salt it had" do
    trail.rows << [ Time.now - 60, "standard_flags.flag.value_set",
                    { "key" => "new_checkout", "after" => { "status" => "draft", "salt" => "then", "hash_version" => 2,
                                                            "percentage_bps" => nil, "rollout_value" => nil, "variant_weights" => {},
                                                            "fallthrough_value" => "on", "stop_value" => nil, "conditions" => {},
                                                            "cohorts" => [] } } ]
    result = restore(Time.now - 30, keys: %w[new_checkout], apply: true)
    expect(entry(result, :new_checkout)).to include(status: "applied", changes: [ "fallthrough - → on" ])
    expect(store.rule(:new_checkout)).to have_attributes(salt: "then", fallthrough_value: "on", status: "draft")
  end

  describe "one write per target" do
    def plain(state) = JSON.parse(JSON.generate(state))

    # Running at T (5%, every platform) and now (100%, iOS only): applied a
    # setting at a time, clearing the platforms before lowering the ramp
    # would serve 100% everywhere, broader than either end.
    def running_both_ends
      store.put_rule(:new_checkout, status: :running, percentage_bps: 500, conditions: {}, salt: "s", hash_version: 2)
      trail.rows << [ Time.now - 120, "standard_flags.flag.ramped", { "key" => "new_checkout", "after" => plain(store.rule(:new_checkout).audit_state) } ]
      store.put_rule(:new_checkout, status: :running, percentage_bps: 10_000, conditions: { "platforms" => %w[ios] }, salt: "s", hash_version: 2)
    end

    def served
      rule = store.rule(:new_checkout)
      [ rule.status, rule.percentage_bps, rule.conditions.to_h ]
    end

    it "never serves a state between the current one and the one at T" do
      running_both_ends
      seen = [ served ]
      allow(store).to receive(:write).and_wrap_original { |original, &block| original.call(&block).tap { seen << served } }
      result = restore(Time.now - 60, keys: %w[new_checkout], apply: true)
      expect(entry(result, :new_checkout)).to include(status: "applied", changes: [ "conditions {\"platforms\":[\"ios\"]} → {}", "percentage 10000 bps → 500 bps" ])
      expect(seen).to eq([ [ "running", 10_000, { "platforms" => %w[ios] } ], [ "running", 500, {} ] ])
    end

    it "leaves the current state when the write fails" do
      running_both_ends
      allow(store).to receive(:tx_save_rule).and_raise(StandardFlags::Runtime::StoreError.new("write failed: IOError", cause_class: "IOError"))
      result = restore(Time.now - 60, keys: %w[new_checkout], apply: true)
      expect(entry(result, :new_checkout)).to include(status: "failed", changes: [], error: "store_error: write failed: IOError")
      expect(served).to eq([ "running", 10_000, { "platforms" => %w[ios] } ])
    end
  end

  describe "partial failure" do
    it "applies the flags it can, and stops a flag at its first failure" do
      op!(ops::CreateCohort, "staff", unit: :account)
      op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
      [ :new_checkout, :global_banner ].each { |key| op!(ops::SetValue, key, value: true) }
      at = checkpoint
      op!(ops::DetachCohort, :new_checkout, cohort: "staff")
      op!(ops::ArchiveCohort, "staff")
      [ :new_checkout, :global_banner ].each { |key| op!(ops::SetValue, key, value: false) }

      result = restore(at, apply: true)
      expect([ result.failure?, result.code ]).to eq([ true, :partial_failure ])
      expect(result.errors).to eq([ "new_checkout: invalid: cohort \"staff\" is archived" ])
      expect(entry(result, :new_checkout)).to include(status: "failed", changes: [],
                                                      notes: [ "nothing was changed; not applied: fallthrough off → on; attach cohort staff → on" ])
      expect(store.rule(:new_checkout).fallthrough_value).to eq("off") # all or nothing
      expect([ entry(result, :global_banner)[:status], store.rule(:global_banner).fallthrough_value ]).to eq(%w[applied on])
    end

    it "stops a flag that changed after it was planned, instead of overwriting it" do
      op!(ops::SetValue, :new_checkout, value: true)
      at = checkpoint
      op!(ops::SetValue, :new_checkout, value: false)
      op!(ops::Ramp, :new_checkout, bps: 100)
      allow(StandardFlags::Operations::RestoreTarget).to receive(:call).and_wrap_original do |original, *args, **kwargs|
        op!(ops::Ramp, :new_checkout, bps: 200) # someone else, between the plan and this write
        original.call(*args, **kwargs)
      end
      result = restore(at, keys: %w[new_checkout], apply: true)
      expect(result.code).to eq(:partial_failure)
      expect(entry(result, :new_checkout)).to include(status: "failed", changes: [])
      expect(entry(result, :new_checkout)[:error]).to start_with("stale_revision: :new_checkout is at revision 4, not 3")
      expect(store.rule(:new_checkout)).to have_attributes(fallthrough_value: "off", percentage_bps: 200)
    end
  end

  describe "flags:restore" do
    def run(env)
      StandardFlags::Tooling::Command.new(env).run(:restore)
    end

    it "prints the plan, and applies it with APPLY=1" do
      op!(ops::SetValue, :new_checkout, value: true)
      at = checkpoint
      op!(ops::SetValue, :new_checkout, value: false)
      allow(StandardFlags::AuditTrail).to receive_messages(new: trail, available?: true)

      dry = run("AT" => at.iso8601(6), "REASON" => "oops")
      expect(dry).to be_ok
      expect(dry.message).to eq("flags:restore to #{at.utc.iso8601} (dry run; APPLY=1 applies it)\n  new_checkout: planned: fallthrough off → on")
      applied = run("AT" => at.iso8601(6), "REASON" => "oops", "APPLY" => "1", "KEYS" => "new_checkout")
      expect(applied.message).to eq("flags:restore to #{at.utc.iso8601} (applied)\n  new_checkout: applied: fallthrough off → on")
      expect(store.rule(:new_checkout).fallthrough_value).to eq("on")
      expect(run("AT" => at.iso8601(6), "REASON" => "oops", "KEYS" => "home_hero").message)
        .to end_with("  home_hero: skipped\n    note: no audit history at T; left unchanged")
    end

    it "prints failures, notes and errors" do
      allow(described_class).to receive(:call).and_return(
        StandardFlags::Result.new(success: false, code: :partial_failure, errors: [ "x: boom" ],
                                  value: { at: "2026-11-20T09:00:00Z", applied: true,
                                           entries: [ { target: "x", status: "failed", changes: [], notes: [ "a note" ], error: "boom" } ] })
      )
      outcome = run("AT" => "2026-11-20T09:00:00Z", "REASON" => "oops", "APPLY" => "1")
      expect(outcome).not_to be_ok
      expect(outcome.message).to eq("flags:restore to 2026-11-20T09:00:00Z (applied)\n  x: failed\n    error: boom\n    note: a note\n" \
                                    "flags:restore: 1 failed (partial_failure)")
    end

    it "says when there is nothing to restore, and refuses a bad or missing AT or REASON" do
      allow(described_class).to receive(:call).and_return(StandardFlags::Result.success({ at: "t", applied: false, entries: [] }))
      expect(run("AT" => "2026-11-20T09:00:00Z", "REASON" => "oops").message).to end_with("  nothing to restore")
      expect(run("AT" => "yesterday", "REASON" => "oops").message)
        .to eq("flags:restore: AT= must be an ISO 8601 time with a zone (Z or an offset), e.g. 2026-11-20T09:00:00Z")
      expect(run("REASON" => "oops").message).to eq("flags:restore: AT= is required")
      expect(run("AT" => "2026-11-20T09:00:00Z").message).to include("REASON= is required")
    end

    # A bare local time would be read in the server's zone, which may not
    # be the operator's.
    it "refuses an AT with no zone, and takes Z or an offset" do
      allow(described_class).to receive(:call).and_return(StandardFlags::Result.success({ at: "t", applied: false, entries: [] }))
      expect(run("AT" => "2026-11-20T09:00:00", "REASON" => "oops").message).to include("AT= must be an ISO 8601 time with a zone")
      expect(run("AT" => "2026-13-45T09:00:00Z", "REASON" => "oops").message).to include("AT= must be an ISO 8601 time with a zone")
      expect(run("AT" => "2026-11-20T09:00:00+08:00", "REASON" => "oops").message).to end_with("  nothing to restore")
      expect(described_class).to have_received(:call).with(hash_including(at: Time.utc(2026, 11, 20, 1))).once
    end

    it "refuses with the Result's code when the restore can't start" do
      expect(run("AT" => (Time.now + 3_600).iso8601, "REASON" => "oops").message).to start_with("flags:restore: refused (invalid)")
    end

    it "is a rake task" do
      allow(described_class).to receive(:call).and_return(StandardFlags::Result.success({ at: "t", applied: false, entries: [] }))
      env = { "AT" => "2026-11-20T09:00:00Z", "REASON" => "oops" }
      stub_const("ENV", ENV.to_h.merge(env))
      expect { RakeTasks.invoke("flags:restore") }.to output(/nothing to restore/).to_stdout
    end
  end

  # Stored unit keys are already normalised: a `key:` that reads a record
  # can't take one, and must not be asked to.
  describe "with a unit whose key: reads a record", registry: RuntimeHelpers::USER_BY_PHONE do
    let(:person) { Struct.new(:phone).new("+6591234567") }

    it "puts back members as the store holds them, without the unit's key:" do
      op!(ops::AddMembers, :beta, keys: [ person ])
      at = checkpoint
      op!(ops::RemoveMembers, :beta, keys: [ person ])
      result = restore(at, keys: %w[beta], apply: true)
      expect(entry(result, :beta)).to include(status: "applied", changes: [ "members +1 (user → on)" ])
      expect(member_keys(rule: :beta)).to eq([ "+6591234567" ])
    end

    it "takes normalized: only as true or false" do
      expect(op(ops::AddMembers, :beta, keys: [ "+6591234567" ], normalized: "yes").errors).to eq([ "normalized: must be true or false" ])
    end

    it "keeps normalized: true to system actors" do
      user = OperationHelpers::User.new(1)
      StandardFlags.config.authorize = ->(*) { true }
      refused = ops::AddMembers.call(:beta, keys: [ "+6591234567" ], normalized: true, actor: user, reason: "x")
      expect(refused.errors).to eq([ "normalized: is for system actors only" ])
      expect(op!(ops::AddMembers, :beta, keys: [ "+6591234567" ], normalized: true).value).to include(added: 1)
      expect(StandardFlags::MCP.tool("add_members").call({ "key" => "beta", "keys" => [ "x" ], "reason" => "x", "normalized" => true }, actor: user))
        .to include("error" => include("code" => "invalid_arguments"))
    end
  end
end
