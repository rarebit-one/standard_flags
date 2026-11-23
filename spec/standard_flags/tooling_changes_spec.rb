require "spec_helper"

RSpec.describe StandardFlags::Tooling, registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
  end

  def command(task, **env)
    StandardFlags::Tooling::Command.new(env.transform_keys(&:to_s)).run(task)
  end

  describe "Command" do
    it "runs each change as the rake system actor and prints the new revision" do
      expect(command(:ramp, KEY: "new_checkout", BPS: "2500", REASON: "canary").message)
        .to eq("flags:ramp new_checkout: ok, revision 1 (status draft)")
      expect(command(:set, KEY: "new_checkout", VALUE: "on", REASON: "x").message).to include("revision 2")
      expect(command(:ramp, KEY: "strict_gates", BPS: "100", VALUE: "on", REASON: "x")).to be_ok
      expect(store.rule(:strict_gates).rollout_value).to eq("on")
    end

    it "says when flags:set started a draft, and warns when the rule is paused" do
      expect(command(:set, KEY: "ai_assistant", VALUE: "off", REASON: "incident").message)
        .to eq("flags:set ai_assistant: ok, revision 1 (status running, started)")
      expect(command(:pause, KEY: "ai_assistant", REASON: "x")).to be_ok
      expect(command(:set, KEY: "ai_assistant", VALUE: "on", REASON: "later").message)
        .to eq("flags:set ai_assistant: ok, revision 3 (status paused)\n" \
               "  warning: rule is paused; the value is stored but not served until Start")
    end

    it "starts, pauses and stops" do
      store.put_rule(:new_checkout, status: :draft)
      expect(command(:start, KEY: "new_checkout", REASON: "x").message).to include("status running")
      expect(command(:pause, KEY: "new_checkout", REASON: "x").message).to include("status paused")
      expect(command(:stop, KEY: "new_checkout", SERVE: "off", REASON: "x").message).to include("status stopped")
      expect(store.rule(:new_checkout)).to have_attributes(status: "stopped", stop_value: "off")
    end

    it "adds and removes members on flags and cohorts" do
      store.put_cohort(:staff, unit: :account)
      expect(command(:members_add, KEY: "new_checkout", KEYS: "a, b", VALUE: "off", REASON: "x").message)
        .to eq("flags:members:add new_checkout: ok, revision 1 (status draft, 2 added, 0 updated)")
      expiry = (Time.now.utc + 600).iso8601
      expect(command(:members_add, KEY: "cohort:staff", KEYS: "a", UNIT: "account", EXPIRES_AT: expiry, REASON: "x").message)
        .to eq("flags:members:add cohort:staff: ok, revision 3 (1 added, 0 updated)")
      expect(command(:members_remove, KEY: "new_checkout", KEYS: "a", REASON: "x").message).to include("1 removed")
    end

    it "refuses pinned flags with a clear message" do
      StandardFlags.config.env_source = { "STANDARD_FLAGS_NEW_CHECKOUT" => "true" }
      outcome = command(:ramp, KEY: "new_checkout", BPS: "100", REASON: "x")
      expect(outcome).not_to be_ok
      expect(outcome.message).to eq("flags:ramp new_checkout: refused (pinned_by_env): flag :new_checkout is pinned by " \
                                    "STANDARD_FLAGS_NEW_CHECKOUT; unset it to change the flag here")
    end

    {
      "REASON=" => [ :ramp, { KEY: "new_checkout", BPS: "1" }, "flags:ramp: REASON= is required (it is written to the audit log)" ],
      "KEY=" => [ :ramp, { BPS: "1", REASON: "x" }, "flags:ramp: KEY= is required" ],
      "BPS=" => [ :ramp, { KEY: "new_checkout", REASON: "x" }, "flags:ramp: BPS= is required" ],
      "an Integer BPS=" => [ :ramp, { KEY: "new_checkout", BPS: "lots", REASON: "x" }, "flags:ramp: invalid value for Integer(): \"lots\"" ],
      "KEYS=" => [ :members_add, { KEY: "new_checkout", REASON: "x" }, "flags:members:add: KEYS= is required" ],
      "a known task" => [ :explode, { KEY: "new_checkout", REASON: "x" }, "flags:explode: unknown task :explode" ]
    }.each do |name, (task, env, message)|
      it "needs #{name}" do
        expect(command(task, **env)).to have_attributes(ok?: false, message: message)
      end
    end

    it "purges as the system actor" do
      store.put_rule(:new_checkout, status: :running)
      store.add_member(rule: :new_checkout, unit: :account, unit_key: "1", value: true, expires_at: Time.now - 100 * 86_400)
      expect(command(:purge).message).to include("REASON=")
      expect(command(:purge, REASON: "weekly").message).to eq("flags:purge: deleted 0 removed and 1 expired memberships")
      allow(store).to receive(:purge).and_raise(IOError)
      expect(command(:purge, REASON: "weekly").message).to eq("flags:purge: could not purge (IOError)")
      StandardFlags.config.runtime_rules = false
      StandardFlags.config.runtime_store = nil
      expect(command(:purge, REASON: "weekly").message).to eq("flags:purge: runtime rules are off")
    end
  end

  describe StandardFlags::Tooling::Show do
    it "shows the declaration, the value here, a pin and the stored rule" do
      store.put_rule(:new_checkout, status: :running, percentage_bps: 10_000, rollout_value: true, full_since: Time.utc(2026, 11, 1),
                                    variant_weights: {}, conditions: { "platforms" => [ "ios" ] }, cohorts: { staff: true })
      StandardFlags.config.env_source = { "STANDARD_FLAGS_NEW_CHECKOUT" => "false" }
      expect(described_class.new("new_checkout").render).to include(
        "new_checkout (flag, owner: payments, unit: account)", "value here: false (ENV_PIN)",
        "pinned by STANDARD_FLAGS_NEW_CHECKOUT", "rule: running, revision 0 (store revision 1)",
        "percentage: 10000 bps → on, full since 2026-11-01T00:00:00Z",
        'conditions: {"platforms":["ios"]}', "cohorts: staff → on", "members: 0"
      )
    end

    it "handles a flag with no rule, an unknown key, runtime rules off and a failing store" do
      expect(described_class.new("strict_gates").render).to include("rule: none (store revision 0)")
      expect(described_class.new("nope").render).to eq("unknown flag :nope")
      allow(store).to receive(:load).and_raise(IOError)
      expect(described_class.new("strict_gates").render).to include("could not read the store (IOError)")
      StandardFlags.config.runtime_rules = false
      StandardFlags.config.runtime_store = nil
      expect(described_class.new("strict_gates").render).to include("runtime rules are off")
      expect(described_class.new("cohort:staff").render).to eq("runtime rules are off")
    end

    it "shows a cohort" do
      store.put_cohort(:staff, unit: :account, name: "Staff", archived_at: Time.utc(2026, 11, 2))
      store.put_rule(:new_checkout, status: :running, cohorts: { staff: true })
      text = described_class.new("cohort:staff").render
      expect(text).to eq("cohort staff (unit: account, archived 2026-11-02T00:00:00Z)\n  Staff\n  members: 0\n  attached to: :new_checkout")
      expect(described_class.new("cohort:nope").render).to eq('unknown cohort "nope"')
    end
  end

  describe "flags:stale with runtime rules" do
    let(:now) { Time.utc(2026, 11, 23, 12) }
    let(:old) { now - 40 * 86_400 }

    def stale
      StandardFlags::Tooling::Stale.new(now: now, today: now.to_date)
    end

    it "lists settled, unused and orphaned rules and memberships due for purge" do
      store.put_rule(:new_checkout, status: :running, percentage_bps: 10_000, full_since: old, last_evaluated_at: now, updated_at: old)
      store.put_rule(:strict_gates, status: :stopped, updated_at: old, last_evaluated_at: now)
      store.put_rule(:home_hero, status: :running, last_evaluated_at: now - 20 * 86_400, updated_at: old)
      store.put_rule(:ai_assistant, status: :running, updated_at: old)
      store.put_rule(:phone_login, status: :running, updated_at: now, last_evaluated_at: now)
      store.put_rule(:old_banner, status: :running, last_evaluated_at: now, updated_at: now)
      store.put_rule(:mystery, status: :draft, last_evaluated_at: now, updated_at: now)
      store.add_member(rule: :phone_login, unit: :phone, unit_key: "1", value: true, expires_at: now - 100 * 86_400)

      expect(stale.runtime_findings).to eq([
        "rule :ai_assistant has not been evaluated since it changed on 2026-10-14",
        "rule :home_hero has not been evaluated since 2026-11-03",
        "rule :mystery is for an undeclared flag",
        "rule :new_checkout has served 100% since 2026-10-14; remove the flag or Stop it",
        "rule :old_banner is for a tombstoned flag",
        "rule :strict_gates has been stopped since 2026-10-14; remove the flag",
        "0 removed and 1 expired memberships are past retention; run flags:purge"
      ])
      expect(stale.render).to start_with("No flags are past their remove_by date.\nrule :ai_assistant")
    end

    it "skips evaluation findings when tracking is off, and says when nothing is stale" do
      store.put_rule(:home_hero, status: :running, updated_at: old)
      StandardFlags.config.track_evaluations = false
      expect(stale.render).to eq("No flags are past their remove_by date.\nNo stale runtime rules.")
    end

    it "reports a store it can't read" do
      allow(store).to receive(:load).and_raise(StandardFlags::Runtime::StoreError.new("x", cause_class: "PG::Error"))
      expect(stale.render).to include("runtime rules: could not read the store (PG::Error)")
    end
  end

  describe "rake tasks" do
    around do |example|
      saved = ENV.to_h.slice("KEY", "BPS", "REASON")
      example.run
    ensure
      %w[KEY BPS REASON].each { |name| saved.key?(name) ? ENV[name] = saved[name] : ENV.delete(name) }
    end

    it "changes a flag and aborts on a refusal" do
      ENV.update("KEY" => "new_checkout", "BPS" => "100", "REASON" => "canary")
      expect { RakeTasks.invoke("flags:ramp") }.to output("flags:ramp new_checkout: ok, revision 1 (status draft)\n").to_stdout
      ENV["BPS"] = "20000"
      expect { expect { RakeTasks.invoke("flags:ramp") }.to raise_error(SystemExit) }.to output(/refused \(invalid\)/).to_stderr
    end

    it "shows a flag and needs KEY=" do
      ENV["KEY"] = "new_checkout"
      expect { RakeTasks.invoke("flags:show") }.to output(/value here: false/).to_stdout
      ENV.delete("KEY")
      expect { expect { RakeTasks.invoke("flags:show") }.to raise_error(SystemExit) }.to output(/KEY= is required/).to_stderr
    end
  end
end
