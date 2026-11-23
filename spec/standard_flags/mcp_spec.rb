require "spec_helper"

RSpec.describe StandardFlags::MCP, registry: OperationHelpers::REGISTRY do
  let(:store) { StandardFlags::Runtime::MemoryStore.new }
  let(:calls) { [] }
  let(:user) { OperationHelpers::User.new(7) }
  let(:reader) { OperationHelpers::User.new(8) }

  before do
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store
    calls = self.calls
    users = [ user, reader ]
    # `user` may do anything; `reader` may only read; anyone else nothing.
    StandardFlags.config.authorize = lambda do |actor, scope, key|
      calls << [ actor, scope, key ]
      actor == users.first || (actor == users.last && scope == "flags:read") || actor.is_a?(StandardFlags::Actor)
    end
  end

  def call(name, arguments = {}, actor: user)
    described_class.tool(name).call(arguments, actor: actor)
  end

  def error_code(result)
    result.dig("error", "code")
  end

  describe "the tools" do
    it "are plain objects with a name, a description, a JSON Schema and call(arguments, actor:)" do
      tools = described_class.tools
      expect(tools.map(&:name)).to eq(%w[list_flags get_flag start_flag pause_flag stop_flag ramp_flag set_flag_value
                                         list_members add_members remove_members list_cohorts get_cohort])
      expect(tools.map(&:description)).to all(be_a(String).and(satisfy { |d| d.length > 20 }))
      expect(tools.map(&:input_schema)).to all(include("type" => "object", "additionalProperties" => false))
      expect(tools.map { |tool| JSON.parse(JSON.generate(tool.input_schema)) }).to eq(tools.map(&:input_schema))
      expect([ tools.map { |tool| tool.method(:call).parameters }.uniq, described_class.tool("nope") ])
        .to eq([ [ [ [ :req, :arguments ], [ :keyreq, :actor ] ] ], nil ])
    end

    it "every write needs a reason, and takes expected_revision" do
      %w[start_flag pause_flag stop_flag ramp_flag set_flag_value add_members remove_members].each do |name|
        schema = described_class.tool(name).input_schema
        expect(schema["required"]).to include("reason")
        expect(schema["properties"]).to include("expected_revision" => include("type" => "integer"))
      end
    end

    it "adapt to a generic tool registry in a few lines" do
      registry = {}
      register = ->(name:, description:, schema:, &handler) { registry[name] = { description: description, schema: schema, handler: handler } }
      described_class.tools.each do |tool|
        register.call(name: tool.name, description: tool.description, schema: tool.input_schema) do |args, actor|
          tool.call(args, actor: actor)
        end
      end
      expect(registry.size).to eq(12)
      expect(registry["get_flag"][:handler].call({ "key" => "new_checkout" }, user)).to include("key" => "new_checkout")
    end

    it "pin a registry when given one" do
      other = StandardFlags.define { flag :other, owner: "x", remove_by: "2099-01-01", final: true }
      StandardFlags.define(&OperationHelpers::REGISTRY)
      result = described_class.tool("list_flags", registry: other).call({}, actor: user)
      expect(result["flags"].map { |f| f["key"] }).to eq(%w[other])
    end
  end

  describe "arguments and actors" do
    it "refuses unknown, missing and mistyped arguments" do
      expect(call("get_flag", { "key" => "new_checkout", "extra" => 1 })["error"]).to eq("code" => "invalid_arguments", "message" => "unknown argument(s): extra")
      expect(call("get_flag", {})["error"]["message"]).to eq("missing argument(s): key")
      expect(call("ramp_flag", { key: "new_checkout", bps: "500", reason: "x" })["error"]["message"]).to eq("bps must be integer")
      expect(error_code(described_class.tool("list_flags").call("nope", actor: user))).to eq("invalid_arguments")
      expect(described_class.tool("list_flags").call(nil, actor: user)).to include("flags")
    end

    it "takes Symbol or String keys" do
      expect(call("get_flag", { key: :new_checkout })).to include("key" => "new_checkout")
    end

    it "falls back to config.actor_resolver, and fails without an actor" do
      StandardFlags.config.actor_resolver = -> { user }
      expect(call("get_flag", { "key" => "new_checkout" }, actor: nil)).to include("key" => "new_checkout")
      StandardFlags.config.actor_resolver = nil
      expect(error_code(call("get_flag", { "key" => "new_checkout" }, actor: nil))).to eq("actor_missing")
    end

    it "turns an unexpected error into a structured one, reported by class" do
      allow(StandardFlags::Evaluator).to receive(:evaluate).and_raise(IOError, "acct-7731")
      errors = []
      StandardFlags.config.error_reporter = ->(error, context) { errors << [ error, context ] }
      result = call("get_flag", { "key" => "new_checkout" })
      expect(result["error"]).to eq("code" => "error", "message" => "get_flag failed: IOError")
      expect(errors.map { |e, c| [ e.message, c ] }).to eq([ [ "get_flag failed: IOError", { tool: "get_flag" } ] ])
    end
  end

  describe "list_flags" do
    it "lists each flag with its value, source, pin and rule summary" do
      store.put_rule(:new_checkout, status: :running, percentage_bps: 500)
      StandardFlags.config.env_source = { "STANDARD_FLAGS_GLOBAL_BANNER" => "on" }
      result = call("list_flags")
      expect(result).to include("runtime_rules" => true, "store_revision" => store.revision)
      flags = result["flags"].to_h { |flag| [ flag["key"], flag ] }
      expect(flags["global_banner"]).to include("value" => "on", "reason" => "ENV_PIN", "source" => "env_pin",
                                                "pinned" => { "env_var" => "STANDARD_FLAGS_GLOBAL_BANNER",
                                                              "label" => "Pinned by environment (STANDARD_FLAGS_GLOBAL_BANNER)" })
      expect(flags["new_checkout"]).to include("kind" => "flag", "owner" => "payments", "unit" => "account",
                                               "values" => %w[on off], "pinned" => nil,
                                               "rule" => { "status" => "running", "revision" => 0, "percentage_bps" => 500, "member_count" => 0 })
      expect(flags["strict_gates"]).to include("values" => %w[off sensor on], "source" => "code_default", "rule" => nil)
      expect(JSON.parse(JSON.generate(result))).to eq(result)
    end

    it "asks flags:read for each flag and lists only those allowed" do
      StandardFlags.config.authorize = ->(_actor, scope, key) { scope == "flags:read" && key == :new_checkout }
      expect(call("list_flags")["flags"].map { |f| f["key"] }).to eq(%w[new_checkout])
    end

    it "refuses an actor who may read no flag" do
      expect(error_code(call("list_flags", {}, actor: Object.new))).to eq("unauthorized")
    end

    it "works with runtime rules off" do
      StandardFlags.config.runtime_rules = false
      StandardFlags.config.runtime_store = nil
      result = call("list_flags")
      expect(result).to include("runtime_rules" => false, "store_revision" => nil)
      expect(result["flags"].map { |f| f["rule"] }.uniq).to eq([ nil ])
    end
  end

  describe "get_flag" do
    it "evaluates for one unit key, masking it, with the rule in full" do
      store.put_rule(:new_checkout, status: :running, fallthrough_value: false)
      store.add_member(rule: :new_checkout, unit: :account, unit_key: "acct-7731", value: true)
      result = call("get_flag", { "key" => "new_checkout", "unit" => "account", "unit_key" => "acct-7731", "reason" => "support" })
      expect(result["evaluation"]).to eq("unit_key" => "•••7731", "value" => "on", "variant" => "on", "reason" => "TARGETING_MATCH",
                                         "error_code" => nil, "rule_id" => "allow", "source" => "runtime_rule")
      expect(result["rule"]).to include("status" => "running", "revision" => 0, "fallthrough_value" => "off", "member_count" => 1)
      expect(result).to include("default" => "off", "pinned" => nil, "runtime_rules" => true)
      expect(calls).to eq([ [ user, "flags:read", :new_checkout ], [ user, "flags:write", :new_checkout ] ])
      expect_no_unit_keys(result)
    end

    # Whether one unit matches says whether it is a member: with the masked
    # last four from list_members, a read-only actor could recover keys.
    def probe!(as: user, **options)
      store.put_rule(:phone_login, status: :running)
      store.add_member(rule: :phone_login, unit: :phone, unit_key: "+6591234567", value: true)
      call("get_flag", { "key" => "phone_login", "unit_key" => "+6591234567" }.merge(options.transform_keys(&:to_s)), actor: as)
    end

    it "evaluates for one unit key only with flags:write and a reason" do
      events = events_during do
        expect(probe!(as: reader)).to eq("error" => { "code" => "unauthorized", "message" => "OperationHelpers::User:8 may not flags:write :phone_login" })
        expect(probe!["error"]).to eq("code" => "invalid_arguments", "message" => "a reason is required to evaluate one unit key")
      end
      expect(events).to be_empty
      expect(call("get_flag", { "key" => "phone_login" }, actor: reader)["evaluation"]).to include("unit_key" => nil)
    end

    it "audits an evaluation for one unit key as standard_flags.flag.probed, with counts and no key" do
      result = nil
      events = events_during { result = probe!(reason: "support ticket") }
      expect(result["evaluation"]).to include("rule_id" => "allow")
      expect(events.map(&:first)).to eq([ "standard_flags.flag.probed" ])
      expect(events.first.last).to include(actor: user, actor_label: "OperationHelpers::User:7", reason: "support ticket",
                                           key: :phone_login, unit: "phone", probed: 1)
      expect_no_unit_keys(events, result)
    end

    it "refuses the evaluation when the probe's audit row can't be written and that is fatal" do
      allow(StandardFlags::Operations::Audit).to receive(:record_read)
        .and_raise(StandardFlags::Operations::Failure.new(:audit_failed, "the audit row could not be written (IOError)"))
      result = call("get_flag", { "key" => "new_checkout", "unit_key" => "acct-7731", "reason" => "x" })
      expect(result).to eq("error" => { "code" => "audit_failed", "message" => "the audit row could not be written (IOError); nothing was evaluated" })
    end

    it "normalises the unit key through the unit's key:" do
      store.put_rule(:phone_login, status: :running)
      store.add_member(rule: :phone_login, unit: :phone, unit_key: "+6591234567", value: true)
      expect(call("get_flag", { "key" => "phone_login", "unit_key" => "+65 9123 4567", "reason" => "x" })["evaluation"])
        .to include("rule_id" => "allow", "unit_key" => "•••4567")
    end

    it "evaluates with no unit when no key is given" do
      store.put_rule(:new_checkout, status: :running, percentage_bps: 500)
      expect(call("get_flag", { "key" => "new_checkout" })["evaluation"]).to include("unit_key" => nil, "error_code" => "TARGETING_KEY_MISSING", "source" => "error")
    end

    it "names the pinning variable, never its value" do
      StandardFlags.config.env_source = { "STANDARD_FLAGS_STRICT_GATES" => "sensor" }
      result = call("get_flag", { "key" => "strict_gates" })
      expect(result["pinned"]).to eq("env_var" => "STANDARD_FLAGS_STRICT_GATES", "label" => "Pinned by environment (STANDARD_FLAGS_STRICT_GATES)")
      expect(result["evaluation"]).to include("source" => "env_pin", "reason" => "ENV_PIN")
    end

    it "reports guards and test overrides as their source" do
      define_flags { flag :internal, owner: "x", remove_by: "2099-01-01", final: true, forbidden_in: :test }
      expect(call("get_flag", { "key" => "internal" })["evaluation"]["source"]).to eq("guard")
      with_flag(:internal, true) { expect(call("get_flag", { "key" => "internal" })["evaluation"]["source"]).to eq("test_override") }
    end

    it "refuses unknown and tombstoned keys" do
      expect(error_code(call("get_flag", { "key" => "nope" }))).to eq("unknown_flag")
      expect(call("get_flag", { "key" => "old_banner" })["error"]).to eq("code" => "tombstoned_flag", "message" => "flag :old_banner was removed on 2026-01-01")
    end

    it "refuses a wrong unit, a unitless flag and a blank or bad unit key" do
      expect(call("get_flag", { "key" => "new_checkout", "unit" => "phone" })["error"]["message"]).to include("is not :new_checkout's unit")
      expect(call("get_flag", { "key" => "global_banner", "unit_key" => "x" })["error"]["message"]).to include("has no unit")
      expect(call("get_flag", { "key" => "new_checkout", "unit_key" => " ", "reason" => "x" })["error"]["message"]).to eq("unit_key is blank")
      define_flags do
        unit :odd, from: ->(ctx) { ctx.odd }, key: ->(_value) { raise TypeError }
        flag :odd_flag, owner: "x", remove_by: "2099-01-01", final: true, unit: :odd
      end
      expect(call("get_flag", { "key" => "odd_flag", "unit_key" => "+65", "reason" => "x" })["error"]["message"]).to include("could not be normalised for :odd (TypeError)")
    end

    it "needs flags:read" do
      expect(call("get_flag", { "key" => "new_checkout" }, actor: Object.new)["error"]).to include("code" => "unauthorized")
    end

    it "treats a raising policy as a refusal and reports it" do
      StandardFlags.config.authorize = ->(*) { raise "policy down" }
      errors = []
      StandardFlags.config.error_reporter = ->(error, context) { errors << [ error.message, context ] }
      expect(error_code(call("get_flag", { "key" => "new_checkout" }))).to eq("unauthorized")
      expect(errors).to eq([ [ "policy down", { tool: "get_flag" } ] ])
    end

    it "fails cleanly when the store can't be read" do
      allow(store).to receive(:load).and_raise(StandardFlags::Runtime::StoreError.new("rule load failed", cause_class: "PG::ConnectionBad"))
      expect(call("get_flag", { "key" => "new_checkout" })["error"]).to eq("code" => "store_error", "message" => "could not read the store (PG::ConnectionBad)")
    end

    it "shows no store revision when the store can't answer" do
      allow(store).to receive(:revision).and_raise(IOError)
      expect(call("get_flag", { "key" => "new_checkout" })["store_revision"]).to be_nil
    end
  end

  describe "the write tools" do
    it "run the operation and return its value" do
      result = call("ramp_flag", { "key" => "new_checkout", "bps" => 500, "reason" => "canary" })
      expect(result).to include("key" => "new_checkout", "revision" => 1, "store_revision" => 1,
                                "rule" => include("percentage_bps" => 500, "status" => "draft"))
      rules = [
        call("start_flag", { "key" => "new_checkout", "reason" => "go", "expected_revision" => 1 }),
        call("pause_flag", { "key" => "new_checkout", "reason" => "hold" }),
        call("stop_flag", { "key" => "new_checkout", "serve" => "on", "reason" => "won" })
      ].map { |r| r["rule"].values_at("status", "stop_value") }
      expect(rules).to eq([ [ "running", nil ], [ "paused", nil ], %w[stopped on] ])
    end

    it "set and clear a value, and ramp to one" do
      expect(call("set_flag_value", { "key" => "strict_gates", "value" => "on", "reason" => "go" })["rule"]).to include("fallthrough_value" => "on")
      expect(call("set_flag_value", { "key" => "strict_gates", "value" => nil, "reason" => "clear" })["rule"]).to include("fallthrough_value" => nil)
      expect(call("ramp_flag", { "key" => "strict_gates", "bps" => 100, "value" => "sensor", "reason" => "x" })["rule"]).to include("rollout_value" => "sensor")
    end

    it "say when set_flag_value started a draft, and warn when the rule is paused" do
      started = call("set_flag_value", { "key" => "ai_assistant", "value" => "off", "reason" => "incident" })
      expect(started).to include("started" => true, "rule" => include("status" => "running", "fallthrough_value" => "off"))
      expect(started).not_to have_key("warnings")
      call("pause_flag", { "key" => "ai_assistant", "reason" => "hold" })
      paused = call("set_flag_value", { "key" => "ai_assistant", "value" => "on", "reason" => "later" })
      expect(paused).to include("started" => false, "rule" => include("status" => "paused"),
                                "warnings" => [ "rule is paused; the value is stored but not served until Start" ])
    end

    it "return the operation's failure code" do
      call("ramp_flag", { "key" => "new_checkout", "bps" => 500, "reason" => "canary" })
      expect(call("start_flag", { "key" => "new_checkout", "reason" => "go", "expected_revision" => 0 })["error"])
        .to eq("code" => "stale_revision", "message" => ":new_checkout is at revision 1, not 0; reload and try again")
      codes = [
        call("ramp_flag", { "key" => "home_hero", "bps" => 500, "reason" => "x" }, actor: reader),
        call("ramp_flag", { "key" => "new_checkout", "bps" => 50_000, "reason" => "x" }),
        call("start_flag", { "key" => "new_checkout", "reason" => " " })
      ].map { |result| error_code(result) }
      expect(codes).to eq(%w[unauthorized invalid invalid])
      StandardFlags.config.env_source = { "STANDARD_FLAGS_NEW_CHECKOUT" => "on" }
      expect(error_code(call("pause_flag", { "key" => "new_checkout", "reason" => "x" }))).to eq("pinned_by_env")
    end
  end

  describe "the member tools" do
    before do
      store.put_rule(:new_checkout, status: :running)
      store.put_cohort(:staff, unit: :account)
    end

    it "add and remove members of a flag or a cohort, never echoing a key" do
      added = call("add_members", { "key" => "new_checkout", "keys" => OperationHelpers::SECRET_KEYS.first(2), "reason" => "pilot",
                                    "expires_at" => (Time.now.utc + 3_600).iso8601 })
      expect(added).to include("unit" => "account", "value" => "on", "added" => 2, "requested" => 2)
      removed = call("remove_members", { "key" => "new_checkout", "keys" => [ "acct-7731" ], "reason" => "done" })
      expect(removed).to include("removed" => 1)
      cohort = call("add_members", { "cohort" => "staff", "keys" => [ "acct-7732" ], "reason" => "new hire" })
      expect(cohort).to include("cohort" => "staff", "added" => 1)
      expect(call("remove_members", { "cohort" => "cohort:staff", "keys" => [ "acct-7732" ], "unit" => "account", "reason" => "x" })).to include("removed" => 1)
      expect_no_unit_keys(added, removed, cohort)
    end

    it "refuse a missing or doubled target and a bad expiry" do
      expect(call("add_members", { "keys" => [ "a" ], "reason" => "x" })["error"]["message"]).to eq("give exactly one of key or cohort")
      expect(error_code(call("add_members", { "key" => "new_checkout", "cohort" => "staff", "keys" => [ "a" ], "reason" => "x" }))).to eq("invalid_arguments")
      expect(call("add_members", { "key" => "new_checkout", "keys" => [ "a" ], "reason" => "x", "expires_at" => "soon" })["error"]["message"])
        .to eq("expires_at must be an ISO 8601 time")
      expect(error_code(call("remove_members", { "key" => "nope", "keys" => [ "a" ], "reason" => "x" }))).to eq("unknown_flag")
    end

    describe "list_members" do
      before do
        %w[acct-7731 acct-7732 +6591234567 42].each_with_index do |key, index|
          store.add_member(rule: :new_checkout, unit: :account, unit_key: key, value: index.even?, expires_at: (Time.now - 60 if key == "42"))
        end
        store.add_member(cohort: :staff, unit: :account, unit_key: "acct-7731", value: true)
      end

      it "masks unit keys and pages" do
        page = call("list_members", { "key" => "new_checkout", "limit" => 3 })
        expect(page).to include("key" => "new_checkout", "total" => 4, "offset" => 0, "limit" => 3, "next_offset" => 3, "revealed" => false)
        expect(page["members"].map { |m| m["unit_key"] }).to eq(%w[•••7731 •••7732 •••4567])
        expect(page["members"].first).to include("unit" => "account", "value" => "on", "expires_at" => nil, "expired" => false,
                                                 "added_at" => match(/\A\d{4}-\d\d-\d\dT/))
        last = call("list_members", { "key" => "new_checkout", "offset" => 3, "limit" => 3 })
        expect(last).to include("next_offset" => nil, "members" => [ include("unit_key" => "•••2", "value" => "off", "expired" => true) ])
        expect_no_unit_keys(page)
      end

      it "lists a cohort's members, and an owner that doesn't exist as empty" do
        expect(call("list_members", { "cohort" => "staff" })).to include("cohort" => "staff", "total" => 1)
        expect(call("list_members", { "cohort" => "ghost" })).to include("total" => 0, "members" => [])
        expect(call("list_members", { "key" => "home_hero" })).to include("total" => 0)
      end

      it "reveals keys to an actor allowed flags:write, with a reason, and audits counts only" do
        page = nil
        events = events_during { page = call("list_members", { "key" => "new_checkout", "reveal" => true, "reason" => "support ticket" }) }
        expect([ page["members"].map { |m| m["unit_key"] }, page["revealed"] ]).to eq([ %w[acct-7731 acct-7732 +6591234567 42], true ])
        expect(events.map(&:first)).to eq([ "standard_flags.members.revealed" ])
        payload = events.first.last
        expect(payload).to include(actor: user, actor_label: "OperationHelpers::User:7", reason: "support ticket",
                                   key: :new_checkout, units: [ "account" ], revealed: 4, total: 4)
        expect_no_unit_keys(payload)
        expect(calls).to include([ user, "flags:write", :new_checkout ])
      end

      it "refuses a reveal without flags:write or a reason" do
        expect(error_code(call("list_members", { "key" => "new_checkout", "reveal" => true, "reason" => "x" }, actor: reader))).to eq("unauthorized")
        expect(call("list_members", { "key" => "new_checkout", "reveal" => true })["error"]["message"]).to eq("a reason is required to reveal unit keys")
        expect(call("list_members", { "key" => "new_checkout" }, actor: reader)).to include("total" => 4)
      end

      it "reveals nothing when the audit row can't be written and the app requires it" do
        allow(StandardFlags::Operations::Audit).to receive(:record_read)
          .and_raise(StandardFlags::Operations::Failure.new(:audit_failed, "the audit row could not be written (IOError)"))
        result = call("list_members", { "key" => "new_checkout", "reveal" => true, "reason" => "x" })
        expect(result["error"]).to eq("code" => "audit_failed", "message" => "the audit row could not be written (IOError); nothing was revealed")
        expect_no_unit_keys(result)
      end

      it "refuses bad bounds, runtime rules off and an unreadable store" do
        expect(error_code(call("list_members", { "key" => "new_checkout", "offset" => -1 }))).to eq("invalid_arguments")
        expect(error_code(call("list_members", { "key" => "new_checkout", "limit" => 201 }))).to eq("invalid_arguments")
        allow(store).to receive(:members).and_raise(StandardFlags::Runtime::StoreError.new("x", cause_class: "PG::ConnectionBad"))
        expect(call("list_members", { "key" => "new_checkout" })["error"]).to eq("code" => "store_error", "message" => "could not read the store (PG::ConnectionBad)")
        StandardFlags.config.runtime_rules = false
        StandardFlags.config.runtime_store = nil
        expect(error_code(call("list_members", { "key" => "new_checkout" }))).to eq("runtime_rules_off")
      end
    end
  end

  describe "the cohort tools" do
    before do
      store.put_cohort(:staff, unit: :account, name: "Staff")
      store.put_cohort(:alumni, unit: :account, archived_at: Time.utc(2026, 1, 1))
      store.put_rule(:new_checkout, status: :running, cohorts: { staff: true })
      store.add_member(cohort: :staff, unit: :account, unit_key: "acct-7731", value: true)
    end

    it "list cohorts with what they attach to, archived ones on request" do
      result = call("list_cohorts")
      expect(result["cohorts"]).to eq([ { "key" => "staff", "name" => "Staff", "description" => nil, "unit" => "account", "member_count" => 1,
                                          "archived_at" => nil, "archived" => false, "attached_to" => [ { "key" => "new_checkout", "value" => "on" } ],
                                          "hidden_flags" => 0 } ])
      expect(call("list_cohorts", { "include_archived" => true })["cohorts"].map { |c| c["key"] }).to eq(%w[alumni staff])
      expect(calls).to include([ user, "flags:read", "cohort:staff" ])
    end

    it "list only the cohorts the actor may read" do
      StandardFlags.config.authorize = ->(_actor, _scope, key) { key == "cohort:alumni" }
      expect(call("list_cohorts", { "include_archived" => true })["cohorts"].map { |c| c["key"] }).to eq(%w[alumni])
    end

    it "get one cohort" do
      expect(call("get_cohort", { "cohort" => "cohort:staff" })).to include("key" => "staff", "member_count" => 1, "store_revision" => store.revision)
      expect(error_code(call("get_cohort", { "cohort" => "ghost" }))).to eq("unknown_cohort")
      expect(error_code(call("get_cohort", { "cohort" => "staff" }, actor: Object.new))).to eq("unauthorized")
    end

    it "name only the attached flags the actor may read, counting the rest" do
      StandardFlags.config.authorize = ->(_actor, scope, key) { scope == "flags:read" && key.to_s.start_with?("cohort:") }
      expect(error_code(call("get_flag", { "key" => "new_checkout" }))).to eq("unauthorized")
      expect(call("get_cohort", { "cohort" => "staff" })).to include("attached_to" => [], "hidden_flags" => 1)
      expect(call("list_cohorts")["cohorts"].first).to include("attached_to" => [], "hidden_flags" => 1)
    end

    it "show a flag's attached cohorts only when the actor may read them" do
      store.put_rule(:new_checkout, status: :running, cohorts: { staff: true, alumni: false })
      StandardFlags.config.authorize = ->(_actor, scope, key) { scope == "flags:read" && key != "cohort:alumni" }
      expect(call("get_flag", { "key" => "new_checkout" })["rule"])
        .to include("cohorts" => [ { "cohort" => "staff", "value" => "on" } ], "hidden_cohorts" => 1)
      expect(call("get_flag", { "key" => "new_checkout" }).to_s).not_to include("alumni")
    end

    it "need runtime rules" do
      StandardFlags.config.runtime_rules = false
      StandardFlags.config.runtime_store = nil
      expect(error_code(call("list_cohorts"))).to eq("runtime_rules_off")
      expect(error_code(call("get_cohort", { "cohort" => "staff" }))).to eq("runtime_rules_off")
    end
  end

  describe "one shared instance per tool (as an MCP server registers them)" do
    def shared(name)
      described_class.tools.find { |tool| tool.name == name }
    end

    it "is frozen and keeps nothing between calls" do
      tool = shared("get_flag")
      expect(tool).to be_frozen
      store.put_rule(:new_checkout, status: :running, percentage_bps: 500)
      expect(tool.call({ "key" => "new_checkout" }, actor: user).dig("rule", "percentage_bps")).to eq(500)
      op!(OperationHelpers::Ops::Ramp, :new_checkout, bps: 9_000)
      expect(tool.call({ "key" => "new_checkout" }, actor: user).dig("rule", "percentage_bps")).to eq(9_000)
      expect(tool.instance_variables).to eq([ :@registry ])
    end

    # A reader's reveal is checked while an admin's call runs on the same
    # instance: each call must still be authorised as its own actor.
    # The policy from the top of the file, except that the reader's
    # flags:read check (on the thread with :pause_once) waits for `resume`.
    def pausing_policy(paused, resume)
      admin = user
      reading = reader
      lambda do |actor, scope, _key|
        if actor == reading && scope == "flags:read" && Thread.current[:pause_once]
          Thread.current[:pause_once] = false
          paused << true
          resume.pop # the admin's call runs here
        end
        actor == admin || (actor == reading && scope == "flags:read")
      end
    end

    it "authorises each of two interleaved calls from different actors as its own actor" do
      store.put_rule(:new_checkout, status: :running)
      store.add_member(rule: :new_checkout, unit: :account, unit_key: "acct-7731", value: true)
      paused = Queue.new
      resume = Queue.new
      StandardFlags.config.authorize = pausing_policy(paused, resume)
      tool = shared("list_members")
      thread = Thread.new do
        Thread.current[:pause_once] = true
        tool.call({ "key" => "new_checkout", "reveal" => true, "reason" => "x" }, actor: reader)
      end
      paused.pop
      admin_page = tool.call({ "key" => "new_checkout" }, actor: user)
      resume << true

      expect(thread.value["error"]).to eq("code" => "unauthorized", "message" => "OperationHelpers::User:8 may not flags:write :new_checkout")
      expect(admin_page["members"].map { |m| m["unit_key"] }).to eq([ "•••7731" ])
    end
  end

  describe "evaluation tracking" do
    it "never marks a rule as evaluated from list_flags or get_flag" do
      store.put_rule(:global_banner, status: :paused)
      store.put_rule(:new_checkout, status: :running)
      call("list_flags")
      call("get_flag", { "key" => "new_checkout" })
      call("get_flag", { "key" => "new_checkout", "unit_key" => "acct-1", "reason" => "x" })
      expect(StandardFlags::Runtime.tracker.pending).to eq([])
      StandardFlags.evaluate(:new_checkout, for: for_account("acct-1"))
      expect(StandardFlags::Runtime.tracker.pending).to eq([ :new_checkout ])
    end
  end

  describe ".mask" do
    it "shows the last four characters, fewer for short keys, so at least half stays hidden" do
      expect(described_class.mask("+6591234567")).to eq("•••4567")
      expect(described_class.mask("12345678")).to eq("•••5678")
      expect(described_class.mask("12345")).to eq("•••45")
      expect(described_class.mask("7")).to eq("•••")
      expect(described_class.mask("")).to eq("•••")
    end
  end

  describe ".json" do
    it "makes values JSON-safe" do
      time = Time.utc(2026, 11, 23, 9, 30)
      expect(described_class.json({ a: :b, t: time, d: Date.new(2026, 1, 2), n: [ 1, 2.5, nil, true ], o: Object.new.tap { |o| def o.to_s = "obj" } }))
        .to eq("a" => "b", "t" => "2026-11-23T09:30:00Z", "d" => "2026-01-02", "n" => [ 1, 2.5, nil, true ], "o" => "obj")
    end
  end
end
