require "spec_helper"

RSpec.describe StandardFlags::Operations, registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:ops) { OperationHelpers::Ops }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
  end

  def failure(result, code)
    expect(result).to have_attributes(success?: false, code: code)
    result.errors.join("; ")
  end

  describe "actors and policy" do
    it "fails without an actor or a resolver result" do
      result = ops::Ramp.call(:new_checkout, bps: 1, reason: "x")
      expect(failure(result, :actor_missing)).to include("StandardFlags::Actor.system")
    end

    it "falls back to Current.user and passes actor, scope and key to the policy" do
      user = OperationHelpers::User.new(5)
      stub_const("Current", Class.new { define_singleton_method(:user) { user } })
      calls = []
      StandardFlags.config.authorize = ->(actor, scope, key) { calls << [ actor, scope, key ] }
      ops::Ramp.call(:new_checkout, bps: 1, reason: "x")
      ops::CreateCohort.call("beta", unit: :account, reason: "x")
      expect(calls).to eq([ [ user, "flags:ramp", :new_checkout ], [ user, "flags:write", "cohort:beta" ] ])
    end

    it "uses a configured actor resolver" do
      StandardFlags.config.actor_resolver = -> { StandardFlags::Actor.system("resolver") }
      expect(ops::SetValue.call(:new_checkout, value: true, reason: "x")).to be_success
    end

    it "treats a raising policy as a refusal and reports it" do
      StandardFlags.config.authorize = ->(*) { raise "policy down" }
      errors = collect_errors do
        expect(ops::SetValue.call(:new_checkout, value: true, actor: system_actor, reason: "x").code).to eq(:unauthorized)
      end
      expect(errors.reports.map { |r| r[:error].message }).to eq([ "policy down" ])
    end

    it "lets ramp be granted separately from write" do
      StandardFlags.config.authorize = ->(_actor, scope, _key) { scope == "flags:ramp" }
      user = OperationHelpers::User.new(1)
      expect(ops::Ramp.call(:new_checkout, bps: 100, actor: user, reason: "x")).to be_success
      expect(ops::SetVariants.call(:home_hero, weights: { control: 10_000 }, actor: user, reason: "x")).to be_success
      expect(ops::SetValue.call(:new_checkout, value: true, actor: user, reason: "x").code).to eq(:unauthorized)
    end
  end

  describe "refusals before any write" do
    it "needs a reason" do
      expect(failure(ops::Ramp.call(:new_checkout, bps: 1, actor: system_actor, reason: " "), :invalid)).to eq("a reason is required")
      expect(ops::Ramp.call(:new_checkout, bps: 1, actor: system_actor).code).to eq(:invalid)
    end

    it "checks argument names and expected_revision's type" do
      expect(failure(op(ops::Ramp, :new_checkout, bps: 1, percent: 2), :invalid)).to include("unknown argument(s): percent")
      expect(failure(op(ops::Ramp, :new_checkout), :invalid)).to include("missing argument(s): bps")
      expect(failure(op(ops::Ramp, :new_checkout, bps: 1, expected_revision: "3"), :invalid)).to include("Integer")
    end

    it "refuses unknown and tombstoned keys" do
      expect(failure(op(ops::Pause, :nope), :unknown_flag)).to include(":nope")
      expect(failure(op(ops::Pause, :old_banner), :tombstoned_flag)).to include("2026-01-01")
    end

    it "refuses the wrong kind of target" do
      expect(failure(op(ops::Ramp, "cohort:staff", bps: 1), :invalid)).to include("takes a flag key")
      expect(failure(op(ops::AddMembers, ops.cohort("BAD KEY"), keys: [ 1 ]), :invalid)).to include("must match")
      expect(op(ops::CreateCohort, ops.cohort(:beta), unit: :account)).to be_success
    end

    it "refuses while runtime rules are off" do
      StandardFlags.config.runtime_rules = false
      StandardFlags.config.runtime_store = nil
      expect(failure(op(ops::Ramp, :new_checkout, bps: 1), :runtime_rules_off)).to include("config.runtime_rules")
    end

    it "ignores a pin that doesn't parse (it pins nothing)" do
      StandardFlags.config.env_source = { "STANDARD_FLAGS_NEW_CHECKOUT" => "maybe" }
      expect(op(ops::Ramp, :new_checkout, bps: 1)).to be_success
    end
  end

  describe "rule creation and revisions" do
    it "creates a draft rule with a random salt and hash version 2 on first use, and never changes the salt" do
      op!(ops::Ramp, :new_checkout, bps: 100)
      rule = store.rule(:new_checkout)
      expect(rule).to have_attributes(status: "draft", hash_version: 2, lock_version: 1)
      expect(rule.salt).to match(/\A\h{32}\z/)
      op!(ops::Ramp, :new_checkout, bps: 200)
      expect(store.rule(:new_checkout)).to have_attributes(salt: rule.salt, lock_version: 2)
    end

    it "copies a declared bucketing: into the new rule" do
      op!(ops::Ramp, :legacy_ramp, bps: 100)
      expect(store.rule(:legacy_ramp)).to have_attributes(hash_version: 1, salt: "legacy-salt")
    end

    it "accepts a matching expected_revision" do
      op!(ops::Ramp, :new_checkout, bps: 100, expected_revision: 0)
      expect(op(ops::Ramp, :new_checkout, bps: 200, expected_revision: 1)).to be_success
      expect(failure(op(ops::Ramp, :new_checkout, bps: 300, expected_revision: 1), :stale_revision)).to include("revision 2, not 1")
    end

    it "lets exactly one of two writers holding the same revision win" do
      op!(ops::Ramp, :new_checkout, bps: 100)
      gate = Queue.new
      threads = [ 200, 300 ].map do |bps|
        Thread.new do
          gate.pop
          op(ops::Ramp, :new_checkout, bps: bps, expected_revision: 1)
        end
      end
      2.times { gate << true }
      results = threads.map(&:value)
      expect(results.count(&:success?)).to eq(1)
      expect(results.reject(&:success?).map(&:code)).to eq([ :stale_revision ])
      expect(store.rule(:new_checkout).lock_version).to eq(2)
    end

    it "never reuses a revision number after a rolled-back write" do
      op!(ops::SetValue, :global_banner, value: true)
      expect do
        store.write do |tx|
          StandardFlags::Runtime.bump_revision!(tx)
          raise IOError
        end
      end.to raise_error(IOError)
      expect(store.revision).to eq(1)
      expect(op!(ops::SetValue, :global_banner, value: false).value[:store_revision]).to eq(3)
    end

    it "shows the change to the writing process at once" do
      StandardFlags.config.refresh_interval = 3_600
      expect(StandardFlags.on?(:global_banner)).to be(false)
      op!(ops::SetValue, :global_banner, value: true)
      expect(StandardFlags.on?(:global_banner)).to be(true)
    end

    it "shows the change to the writing process inside a unit of work that pinned the old snapshot" do
      StandardFlags.config.refresh_interval = 3_600
      seen = Rails.application.executor.wrap do
        before = StandardFlags.on?(:global_banner)
        op!(ops::SetValue, :global_banner, value: true)
        [ before, StandardFlags.on?(:global_banner), StandardFlags::Runtime.snapshot.rule(:global_banner)&.status ]
      end
      expect(seen).to eq([ false, true, "running" ])
    end

    # Runs a unit of work on another thread that reads :global_banner, waits
    # while the block runs, then reads it again; returns both reads.
    def read_around_in_another_unit_of_work
      pinned = Queue.new
      resume = Queue.new
      thread = Thread.new do
        Rails.application.executor.wrap { [ StandardFlags.on?(:global_banner).tap { pinned << true }, resume.pop && StandardFlags.on?(:global_banner) ] }
      end
      pinned.pop
      yield
      resume << true
      thread.value
    end

    it "keeps another unit of work's pinned snapshot until that run ends" do
      StandardFlags.config.refresh_interval = 0
      seen = read_around_in_another_unit_of_work do
        op!(ops::SetValue, :global_banner, value: true)
      end
      expect(seen).to eq([ false, false ])
      expect(Rails.application.executor.wrap { StandardFlags.on?(:global_banner) }).to be(true)
    end
  end

  describe "Start, Pause and Stop" do
    it "pauses back to the code default, keeps the settings, and resumes" do
      op!(ops::SetValue, :strict_gates, value: :on)
      expect(StandardFlags.mode(:strict_gates)).to be_on
      op!(ops::Pause, :strict_gates)
      expect(StandardFlags.evaluate(:strict_gates)).to have_attributes(value: :off, reason: "DEFAULT")
      expect(store.rule(:strict_gates).fallthrough_value).to eq("on")
      op!(ops::Start, :strict_gates)
      expect(StandardFlags.mode(:strict_gates)).to be_on
    end

    it "refuses transitions that don't apply" do
      expect(failure(op(ops::Pause, :new_checkout), :invalid)).to include("is draft")
      op!(ops::Start, :new_checkout)
      expect(failure(op(ops::Start, :new_checkout), :invalid)).to include("is running")
      op!(ops::Stop, :new_checkout, serve: true)
      expect(failure(op(ops::Start, :new_checkout), :invalid)).to include("is stopped")
    end

    it "checks the whole rule before starting it" do
      store.put_rule(:strict_gates, status: :draft, percentage_bps: 500)
      expect(failure(op(ops::Start, :strict_gates), :invalid)).to include("no rollout value")
      store.put_rule(:new_checkout, status: :paused, cohorts: { gone: true })
      expect(failure(op(ops::Start, :new_checkout), :invalid)).to include('cohort "gone" does not exist')
      store.put_rule(:home_hero, status: :draft, fallthrough_value: "nope")
      expect(failure(op(ops::Start, :home_hero), :invalid)).to include("fallthrough_value")
      store.put_rule(:global_banner, status: :draft, percentage_bps: 100)
      expect(failure(op(ops::Start, :global_banner), :invalid)).to include("no unit")
    end

    it "stops serving one value to everyone" do
      op!(ops::Stop, :home_hero, serve: "savings")
      expect(StandardFlags.evaluate(:home_hero, for: for_account(1))).to have_attributes(value: "savings", rule_id: "stopped")
      expect(failure(op(ops::Stop, :home_hero, serve: "other"), :invalid)).to include("control/savings/privacy")
    end
  end

  describe "Ramp" do
    it "records full_since at 100%, keeps it, and clears it below" do
      op!(ops::Ramp, :new_checkout, bps: 10_000)
      since = store.rule(:new_checkout).full_since
      expect(since).to be_within(5).of(Time.now.utc)
      op!(ops::Ramp, :new_checkout, bps: 10_000)
      expect(store.rule(:new_checkout).full_since).to eq(since)
      op!(ops::Ramp, :new_checkout, bps: 9_999)
      expect(store.rule(:new_checkout).full_since).to be_nil
    end

    it "validates bps" do
      [ -1, 10_001, "5", 1.5, nil ].each do |bps|
        expect(failure(op(ops::Ramp, :new_checkout, bps: bps), :invalid)).to include("0 to 10000")
      end
    end

    it "needs a unit and, for modes and experiments, a value" do
      expect(failure(op(ops::Ramp, :global_banner, bps: 1), :invalid)).to include("no unit")
      expect(failure(op(ops::Ramp, :strict_gates, bps: 1), :invalid)).to include("pass value:")
      expect(failure(op(ops::Ramp, :strict_gates, bps: 1, value: :loud), :invalid)).to include("off/sensor/on")
      op!(ops::Ramp, :strict_gates, bps: 1, value: :on)
      expect(store.rule(:strict_gates).rollout_value).to eq("on")
    end

    it "serves the percentage once started" do
      salt = nil
      op!(ops::Ramp, :new_checkout, bps: 2_500).then { salt = store.rule(:new_checkout).salt }
      op!(ops::Start, :new_checkout)
      inside = account_id(salt, 2_500, inside: true)
      outside = account_id(salt, 2_500, inside: false)
      expect(StandardFlags.evaluate(:new_checkout, for: for_account(inside))).to have_attributes(value: true, rule_id: "percentage")
      expect(StandardFlags.on?(:new_checkout, for: for_account(outside))).to be(false)
    end
  end

  describe "SetVariants" do
    it "stores weights in declared order, and an empty Hash clears them" do
      op!(ops::SetVariants, :home_hero, weights: { privacy: 2_000, control: 8_000 })
      expect(store.rule(:home_hero).variant_weights.keys).to eq(%w[control privacy])
      op!(ops::SetVariants, :home_hero, weights: {})
      expect(store.rule(:home_hero).variant_weights).to eq({})
    end

    {
      "a sum other than 10,000" => [ :home_hero, { control: 9_000 }, "sum to 10000, not 9000" ],
      "negative weights" => [ :home_hero, { control: 11_000, savings: -1_000 }, "0 or more" ],
      "an undeclared variant" => [ :home_hero, { other: 10_000 }, "variant" ],
      "a value named twice" => [ :home_hero, { control: 10_000, "control" => 0 }, "twice" ],
      "something other than a Hash" => [ :home_hero, [ 1 ], "Hash" ],
      "weights on an on/off flag" => [ :new_checkout, { on: 10_000 }, "on/off flag" ]
    }.each do |name, (key, weights, message)|
      it "refuses #{name}" do
        expect(failure(op(ops::SetVariants, key, weights: weights), :invalid)).to include(message)
      end
    end

    it "takes mode values" do
      op!(ops::SetVariants, :strict_gates, weights: { off: 5_000, on: 5_000 })
      expect(store.rule(:strict_gates).variant_weights).to eq("off" => 5_000, "on" => 5_000)
    end
  end

  describe "SetValue" do
    def events
      seen = []
      subscriber = ActiveSupport::Notifications.subscribe(/\Astandard_flags\.flag\./) { |name, *, payload| seen << [ name, payload ] }
      yield
      seen
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "throws a kill switch from the database, starting the rule it creates on first use" do
      expect(store.rule(:ai_assistant)).to be_nil
      result = op!(ops::SetValue, :ai_assistant, value: false)
      expect(StandardFlags.evaluate(:ai_assistant)).to have_attributes(value: false, reason: "KILL_SWITCH", rule_id: "fallthrough")
      expect(result.value).to include(started: true, revision: 1, store_revision: 1, rule: include(status: "running", fallthrough_value: "off"))
      expect(result.warnings).to eq([])
      expect(store.rule(:ai_assistant)).to have_attributes(status: "running", fallthrough_value: "off", lock_version: 1)
    end

    it "starts a draft in one write: one revision, one value_set event carrying started: true and both changes" do
      op!(ops::Ramp, :new_checkout, bps: 2_500)
      seen = events { op!(ops::SetValue, :new_checkout, value: false) }
      expect(seen.map(&:first)).to eq(%w[standard_flags.flag.value_set])
      payload = seen.first.last
      expect(payload).to include(started: true, revision: 2, store_revision: 2)
      expect(payload[:before]).to include(status: "draft", fallthrough_value: nil, percentage_bps: 2_500)
      expect(payload[:after]).to include(status: "running", fallthrough_value: "off", percentage_bps: 2_500)
      expect(store.revision).to eq(2)
    end

    it "serves what was staged on the draft once it starts" do
      op!(ops::Ramp, :new_checkout, bps: StandardFlags::Bucket::BUCKETS)
      expect(StandardFlags.on?(:new_checkout, for: for_account("acct-1"))).to be(false)
      op!(ops::SetValue, :new_checkout, value: false)
      expect(StandardFlags.evaluate(:new_checkout, for: for_account("acct-1"))).to have_attributes(value: true, rule_id: "percentage")
    end

    it "checks the started rule as Start does, and changes nothing when it fails" do
      store.put_rule(:new_checkout, status: :draft, cohorts: { gone: true })
      rule = store.rule(:new_checkout)
      revision = store.revision
      seen = events { expect(failure(op(ops::SetValue, :new_checkout, value: true), :invalid)).to include('cohort "gone" does not exist') }
      expect(seen).to eq([])
      expect(store.rule(:new_checkout)).to have_attributes(status: "draft", fallthrough_value: nil, lock_version: rule.lock_version)
      expect(store.revision).to eq(revision)
    end

    it "keeps a paused rule paused, storing the value with a warning" do
      op!(ops::SetValue, :strict_gates, value: :sensor)
      op!(ops::Pause, :strict_gates)
      result = op!(ops::SetValue, :strict_gates, value: :on)
      expect(result.warnings).to eq([ "rule is paused; the value is stored but not served until Start" ])
      expect(result.value).to include(started: false, rule: include(status: "paused", fallthrough_value: "on"))
      expect(StandardFlags.evaluate(:strict_gates)).to have_attributes(value: :off, reason: "DEFAULT")
      op!(ops::Start, :strict_gates)
      expect(StandardFlags.mode(:strict_gates)).to be_on
    end

    it "leaves a stopped rule stopped, serving its stop value, without a warning" do
      op!(ops::Stop, :home_hero, serve: "savings")
      result = op!(ops::SetValue, :home_hero, value: "control")
      expect(result.value).to include(started: false, rule: include(status: "stopped", fallthrough_value: "control", stop_value: "savings"))
      expect(result.warnings).to eq([])
      expect(StandardFlags.variant(:home_hero)).to eq("savings")
    end

    it "leaves a running rule running" do
      op!(ops::SetValue, :strict_gates, value: :sensor)
      result = op!(ops::SetValue, :strict_gates, value: :on)
      expect(result.value).to include(started: false, rule: include(status: "running"))
      expect(result.warnings).to eq([])
    end

    it "never starts a rule by clearing its value, and warns only when a value is stored on a paused one" do
      result = op!(ops::SetValue, :global_banner, value: nil)
      expect(result.value).to include(started: false, rule: include(status: "draft"))
      op!(ops::SetValue, :strict_gates, value: :on)
      op!(ops::Pause, :strict_gates)
      expect(op!(ops::SetValue, :strict_gates, value: nil).warnings).to eq([])
    end

    it "leaves Ramp, SetVariants, SetConditions, members and cohorts on a draft staged" do
      store.put_cohort(:staff, unit: :account)
      op!(ops::Ramp, :new_checkout, bps: 500)
      op!(ops::SetConditions, :new_checkout, platforms: %w[ios])
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731])
      op!(ops::RemoveMembers, :new_checkout, keys: %w[acct-7731])
      op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
      op!(ops::DetachCohort, :new_checkout, cohort: "staff")
      op!(ops::SetVariants, :home_hero, weights: { control: 5_000, savings: 5_000 })
      expect([ store.rule(:new_checkout).status, store.rule(:home_hero).status ]).to eq(%w[draft draft])
    end

    it "moves a mode, refuses values the flag can't take, and clears with nil" do
      op!(ops::SetValue, :strict_gates, value: "sensor")
      expect(store.rule(:strict_gates).fallthrough_value).to eq("sensor")
      expect(failure(op(ops::SetValue, :strict_gates, value: :loud), :invalid)).to include("off/sensor/on")
      op!(ops::SetValue, :strict_gates, value: nil)
      expect(store.rule(:strict_gates).fallthrough_value).to be_nil
    end
  end

  describe "SetConditions" do
    it "replaces the conditions and validates them" do
      op!(ops::SetConditions, :new_checkout, platforms: %w[iOS android], versions: { "Android" => ">= 1.4, < 2" }, segments: { beta: true })
      expect(store.rule(:new_checkout).conditions).to eq(
        "platforms" => %w[ios android], "versions" => { "android" => ">= 1.4, < 2" },
        "segments" => [ { "name" => "beta", "value" => "on" } ]
      )
      op!(ops::SetConditions, :new_checkout, platforms: %w[ios])
      expect(store.rule(:new_checkout).conditions).to eq("platforms" => %w[ios])
      op!(ops::SetConditions, :new_checkout, segments: [ { name: "staff", value: false } ])
      expect(store.rule(:new_checkout).segments).to eq([ { "name" => "staff", "value" => "off" } ])
    end

    {
      "a version range that doesn't parse" => [ :new_checkout, { versions: { ios: "around 2" } }, "does not parse" ],
      "versions that aren't a Hash" => [ :new_checkout, { versions: [ "ios" ] }, "Hash" ],
      "a blank platform" => [ :new_checkout, { platforms: [ "" ] }, "list of names" ],
      "a blank segment name" => [ :new_checkout, { segments: { " " => true } }, "blank" ],
      "a segment value the flag can't take" => [ :new_checkout, { segments: { beta: :loud } }, "segment beta" ],
      "segments on a flag with no unit" => [ :global_banner, { segments: { beta: true } }, "no unit" ]
    }.each do |name, (key, args, message)|
      it "refuses #{name}" do
        expect(failure(op(ops::SetConditions, key, **args), :invalid)).to include(message)
      end
    end

    it "limits the size of the conditions" do
      StandardFlags.config.max_conditions_bytes = 100
      expect(failure(op(ops::SetConditions, :new_checkout, platforms: Array.new(20) { |i| "platform#{i}" }), :limit_exceeded)).to include("limit is 100")
    end
  end

  describe "AddMembers and RemoveMembers" do
    it "adds and updates memberships, keeping member_count in step" do
      expect(op!(ops::AddMembers, :new_checkout, keys: [ "acct-7731", account("acct-7732"), "acct-7731" ]).value)
        .to include(added: 2, updated: 0, requested: 2, value: "on", unit: "account")
      expect(op!(ops::AddMembers, :new_checkout, keys: [ "acct-7731" ], value: false).value).to include(added: 0, updated: 1)
      expect(store.rule(:new_checkout).member_count).to eq(2)
      op!(ops::Start, :new_checkout)
      expect(StandardFlags.evaluate(:new_checkout, for: for_account("acct-7731"))).to have_attributes(value: false, rule_id: "deny")
    end

    it "soft-deletes removed memberships" do
      op!(ops::AddMembers, :new_checkout, keys: %w[acct-7731 acct-7732])
      op!(ops::Start, :new_checkout)
      expect(op!(ops::RemoveMembers, :new_checkout, keys: %w[acct-7731 acct-9999]).value).to include(requested: 2, removed: 1)
      expect(store.rule(:new_checkout).member_count).to eq(1)
      expect(store.removed_memberships.map(&:unit_key)).to eq(%w[acct-7731])
      expect(StandardFlags.evaluate(:new_checkout, for: for_account("acct-7731")).reason).to eq("DEFAULT")
    end

    it "lets a subscriber evaluate flags while a write is in progress" do
      seen = []
      subscriber = ActiveSupport::Notifications.subscribe("standard_flags.flag.value_set") { seen << StandardFlags.on?(:global_banner) }
      StandardFlags.config.refresh_interval = 0
      errors = collect_errors { op!(ops::SetValue, :global_banner, value: true) }
      expect([ seen, errors.reports ]).to eq([ [ true ], [] ])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "takes any list of keys, such as a relation" do
      relation = Struct.new(:records) { def to_ary = records }.new([ account(1), account(2) ])
      expect(op!(ops::AddMembers, :new_checkout, keys: relation).value).to include(added: 2)
    end

    it "normalises keys through the unit and never quotes one in an error" do
      op!(ops::AddMembers, :phone_login, keys: [ "+65 9123 4567" ])
      expect(store.memberships(:phone, [ "+6591234567" ]).size).to eq(1)

      define_flags do
        unit :phone, from: ->(ctx) { ctx.phone }, key: ->(phone) { raise ArgumentError, "bad phone #{phone}" }
        flag :phone_login, owner: "identity", remove_by: "2027-01-01", final: true, unit: :phone
      end
      message = failure(op(ops::AddMembers, :phone_login, keys: [ "+6591234567" ]), :invalid)
      expect(message).to eq("a key could not be normalised for :phone (ArgumentError)")
    end

    {
      "a mode member without a value" => [ :strict_gates, { keys: [ 1 ] }, "pass value:" ],
      "a value the flag can't take" => [ :strict_gates, { keys: [ 1 ], value: :loud }, "off/sensor/on" ],
      "members of a flag with no unit" => [ :global_banner, { keys: [ 1 ] }, "no unit" ],
      "a unit other than the flag's" => [ :new_checkout, { keys: [ 1 ], unit: :phone }, "does not match :account" ],
      "blank keys" => [ :new_checkout, { keys: [ "acct-7731", " ", nil ] }, "2 of the keys are blank" ],
      "no keys" => [ :new_checkout, { keys: [] }, "keys must not be empty" ],
      "an expiry in the past" => [ :new_checkout, { keys: [ 1 ], expires_at: Time.now - 1 }, "future" ],
      "an expiry that doesn't parse" => [ :new_checkout, { keys: [ 1 ], expires_at: "soon" }, "ISO 8601" ],
      "an expiry that isn't a time" => [ :new_checkout, { keys: [ 1 ], expires_at: 5 }, "a Time" ]
    }.each do |name, (key, args, message)|
      it "refuses #{name}" do
        expect(failure(op(ops::AddMembers, key, **args), :invalid)).to include(message)
      end
    end

    it "takes a single key, the unit by name, and an ISO 8601 expiry" do
      expires = (Time.now.utc + 3_600).iso8601
      expect(op!(ops::AddMembers, :strict_gates, keys: 7, value: "on", unit: "account", expires_at: expires).value)
        .to include(expires_at: expires, value: "on", requested: 1)
    end

    it "limits keys per operation and live members per owner" do
      StandardFlags.config.max_keys_per_operation = 2
      expect(failure(op(ops::AddMembers, :new_checkout, keys: [ 1, 2, 3 ]), :limit_exceeded)).to include("3 keys")
      expect(failure(op(ops::RemoveMembers, :new_checkout, keys: [ 1, 2, 3 ]), :limit_exceeded)).to include("3 keys")

      StandardFlags.config.max_members = 3
      op!(ops::AddMembers, :new_checkout, keys: [ 1, 2 ])
      op!(ops::AddMembers, :new_checkout, keys: [ 3 ])
      expect(failure(op(ops::AddMembers, :new_checkout, keys: [ 4 ]), :limit_exceeded)).to include(":new_checkout would have 4")
      expect(store.rule(:new_checkout).member_count).to eq(3)

      op!(ops::CreateCohort, "staff", unit: :account)
      op!(ops::AddMembers, "cohort:staff", keys: [ 1, 2 ])
      expect(failure(op(ops::AddMembers, "cohort:staff", keys: [ 3, 4 ]), :limit_exceeded)).to include('cohort "staff" would have 4')
    end

    it "doesn't count expired members against the limit" do
      StandardFlags.config.max_members = 1
      store.put_rule(:new_checkout, status: :running)
      store.add_member(rule: :new_checkout, unit: :account, unit_key: "1", value: true, expires_at: Time.now - 60)
      expect(op(ops::AddMembers, :new_checkout, keys: [ 2 ])).to be_success
    end

    it "manages cohort members" do
      op!(ops::CreateCohort, "staff", unit: :account)
      expect(failure(op(ops::AddMembers, "cohort:staff", keys: [ 1 ], value: true), :invalid)).to include("leave out value:")
      op!(ops::AddMembers, "cohort:staff", keys: [ 1 ])
      expect(store.memberships(:account, [ "1" ]).map(&:value)).to eq([ "on" ])
      expect(failure(op(ops::AddMembers, "cohort:nope", keys: [ 1 ]), :invalid)).to include("does not exist")
      op!(ops::RemoveMembers, "cohort:staff", keys: [ 1 ])
      op!(ops::ArchiveCohort, "staff")
      expect(failure(op(ops::AddMembers, "cohort:staff", keys: [ 1 ]), :invalid)).to include("archived")
      expect(op(ops::RemoveMembers, "cohort:staff", keys: [ 1 ]).value).to include(removed: 0)
    end

    it "refuses members of a cohort whose unit is no longer declared" do
      store.put_cohort(:teams, unit: :team)
      expect(failure(op(ops::AddMembers, "cohort:teams", keys: [ 1 ]), :invalid)).to include(":team, which is not declared")
    end
  end

  describe "cohorts" do
    before { op!(ops::CreateCohort, "staff", unit: :account, name: "Staff", description: "Everyone on the team") }

    it "creates and attaches, re-attaching in place" do
      expect(store.load.cohorts.first).to have_attributes(key: "staff", name: "Staff", description: "Everyone on the team", unit: :account)
      op!(ops::CreateCohort, "beta", unit: :account)
      op!(ops::AttachCohort, :strict_gates, cohort: "staff", value: :sensor)
      op!(ops::AttachCohort, :strict_gates, cohort: "beta", value: :off)
      op!(ops::AttachCohort, :strict_gates, cohort: "cohort:staff", value: :on)
      expect(store.rule(:strict_gates).cohorts).to eq([ { "cohort" => "staff", "value" => "on" }, { "cohort" => "beta", "value" => "off" } ])
    end

    it "detaches and archives, refusing to archive an attached cohort" do
      op!(ops::AttachCohort, :strict_gates, cohort: "staff", value: :on)
      expect(failure(op(ops::ArchiveCohort, "staff"), :invalid)).to include("attached to :strict_gates")
      op!(ops::DetachCohort, :strict_gates, cohort: "staff")
      expect(failure(op(ops::DetachCohort, :strict_gates, cohort: "staff"), :invalid)).to include("not attached")
      op!(ops::ArchiveCohort, "staff")
      expect(failure(op(ops::ArchiveCohort, "staff"), :invalid)).to include("already archived")
      expect(failure(op(ops::AttachCohort, :strict_gates, cohort: "staff", value: :on), :invalid)).to include("archived")
    end

    {
      "an undeclared unit" => [ :CreateCohort, "teams", { unit: :team }, "unknown unit" ],
      "a cohort of another unit" => [ :AttachCohort, :new_checkout, { cohort: "phones", value: true }, "holds :phone units" ],
      "a cohort on a flag with no unit" => [ :AttachCohort, :global_banner, { cohort: "staff", value: true }, "no unit" ],
      "a value the flag can't take" => [ :AttachCohort, :new_checkout, { cohort: "staff", value: :sensor }, "on/off" ],
      "archiving a missing cohort" => [ :ArchiveCohort, "nope", {}, "does not exist" ]
    }.each do |name, (operation, target, args, message)|
      it "refuses #{name}" do
        op!(ops::CreateCohort, "phones", unit: :phone)
        expect(failure(op(ops.const_get(operation), target, **args), :invalid)).to include(message)
      end
    end

    it "refuses a duplicate cohort with :already_exists" do
      expect(failure(op(ops::CreateCohort, "staff", unit: :phone), :already_exists)).to include("already exists")
      expect(store.load.cohorts.find { |c| c.key == "staff" }.unit).to eq(:account)
    end

    it "limits cohorts per rule" do
      StandardFlags.config.max_cohorts_per_rule = 2
      op!(ops::CreateCohort, "beta", unit: :account)
      op!(ops::CreateCohort, "gamma", unit: :account)
      op!(ops::AttachCohort, :new_checkout, cohort: "staff", value: true)
      op!(ops::AttachCohort, :new_checkout, cohort: "beta", value: true)
      expect(failure(op(ops::AttachCohort, :new_checkout, cohort: "gamma", value: true), :limit_exceeded)).to include("limit is 2")
    end

    it "checks a cohort's expected_revision against the store revision" do
      revision = store.revision
      expect(op(ops::AddMembers, "cohort:staff", keys: [ 1 ], expected_revision: revision)).to be_success
      expect(op(ops::ArchiveCohort, "staff", expected_revision: revision).code).to eq(:stale_revision)
    end

    it "serves members through an attached cohort" do
      op!(ops::AddMembers, "cohort:staff", keys: [ "acct-7731" ])
      op!(ops::AttachCohort, :strict_gates, cohort: "staff", value: :on)
      op!(ops::Start, :strict_gates)
      expect(StandardFlags.evaluate(:strict_gates, for: for_account("acct-7731"))).to have_attributes(value: :on, rule_id: "cohort:staff")
    end
  end

  describe "errors" do
    it "reports a store failure and returns :store_error" do
      allow(store).to receive(:write).and_raise(StandardFlags::Runtime::StoreError.new("write failed: PG::Error", cause_class: "PG::Error"))
      errors = collect_errors { expect(failure(op(ops::Ramp, :new_checkout, bps: 1), :store_error)).to eq("write failed: PG::Error") }
      expect(errors.reports.first[:context]).to include(operation: "ramp", flag: "new_checkout")
    end

    it "reports unexpected errors, without the message when the operation handles unit keys" do
      allow(store).to receive(:write).and_raise(RuntimeError, "duplicate acct-7731")
      errors = collect_errors do
        expect(failure(op(ops::AddMembers, :new_checkout, keys: [ "acct-7731" ]), :error)).to eq("add_members failed: RuntimeError")
        expect(op(ops::Ramp, :new_checkout, bps: 1).code).to eq(:error)
      end
      messages = errors.reports.map { |r| r[:error].message }
      expect(messages).to eq([ "add_members failed: RuntimeError", "duplicate acct-7731" ])
    end

    it "rolls the whole write back when a step fails" do
      StandardFlags.config.max_members = 1
      revision = store.revision
      op(ops::AddMembers, :new_checkout, keys: [ 1, 2 ])
      expect(store.revision).to eq(revision)
      expect(store.rule(:new_checkout)).to be_nil
    end

    it "refuses writes on a store that doesn't take them" do
      StandardFlags.config.runtime_store = Class.new(StandardFlags::Runtime::Store) { def revision = 0 }.new
      expect(failure(op(ops::Ramp, :new_checkout, bps: 1), :store_error)).to include("does not support writes")
    end
  end

  it "works against the test helpers' store" do
    with_rule(:new_checkout, status: :draft)
    op!(ops::SetValue, :new_checkout, value: true)
    expect(StandardFlags.on?(:new_checkout)).to be(true)
  end
end
