require "json"
require "time"

module StandardFlags
  module Operations
    # Puts rules and memberships back as they were at a past time T (R16):
    #
    #   StandardFlags::Operations::Restore.call(at: Time.utc(2026, 11, 20, 9), reason: "bad ramp")              # dry run
    #   StandardFlags::Operations::Restore.call(at: ..., keys: %w[new_checkout], apply: true, reason: "bad ramp")
    #
    # * A rule's state at T is the after-state of its latest audit row at or
    #   before T, read through standard_audit's query API (the audit_logs
    #   table). Without standard_audit loaded it fails (:audit_unavailable).
    #   Only an audited state drives a change: a flag with no row at or
    #   before T (rows pruned by the audit log's retention, written before
    #   auditing was set up, or lost) is skipped, "no audit history at T;
    #   left unchanged", never treated as "no rule then".
    # * Memberships at T come from the memberships table: rows created by T
    #   and not removed (or expired) by then. Removed rows are kept for
    #   `config.membership_retention`, so a T older than that is refused
    #   (:retention_exceeded).
    #
    # A dry run (the default) only plans: the Result's value lists each
    # cohort and flag with the changes it would make, member changes as
    # counts. `apply: true` writes each one's state at T as a whole, in one
    # store write (RestoreTarget: one revision bump, one
    # `standard_flags.flag.restored` or `standard_flags.cohort.restored`
    # row), as `Actor.system("restore")`, with the reason "restore to T:
    # <reason>". Nothing in between is ever served, and a target that fails
    # is left as it was. Cohorts go first, so a flag that attaches one
    # serves its members as they were. A flag's write expects the revision
    # it was planned at, so a change made meanwhile stops that flag
    # (:stale_revision) rather than being overwritten. Targets are
    # independent: when some fail, the Result is a failure
    # (:partial_failure) whose value still lists what was applied and what
    # wasn't.
    #
    # Skipped, with a note: ENV-pinned flags, undeclared or tombstoned keys,
    # flags with no audit history at T, and changes the operations don't
    # make (un-stopping a rule, clearing a percentage, changing a rule's
    # salt).
    #
    # Break-glass: run from `flags:restore` or a console, not from a request.
    # It authorises as the system actor, so it is not exposed as an MCP tool.
    class Restore
      ACTOR = Actor.system("restore")
      NO_HISTORY = "no audit history at T; left unchanged".freeze

      # One target's planned write: change summaries, the rule columns to
      # set, and member groups to remove and add (unit keys stay in here).
      Plan = Data.define(:changes, :attributes, :remove, :add) do
        def self.empty
          new(changes: [], attributes: {}, remove: [], add: [])
        end

        def +(other)
          Plan.new(changes: changes + other.changes, attributes: attributes.merge(other.attributes),
                   remove: remove + other.remove, add: add + other.add)
        end
      end

      # One flag or cohort in the plan. `status` is "unchanged", "planned",
      # "skipped", "applied" or "failed".
      Entry = Data.define(:target, :status, :changes, :notes, :error) do
        def to_h
          { target: target, status: status, changes: changes, notes: notes, error: error }.compact
        end
      end

      def self.call(at:, reason:, keys: nil, apply: false, registry: StandardFlags.registry, trail: nil, now: Time.now.utc)
        new(at: at, reason: reason, keys: keys, apply: apply, registry: registry, trail: trail, now: now).call
      end

      def initialize(at:, reason:, keys:, apply:, registry:, trail:, now:)
        @at = at
        @reason = reason
        @keys = keys
        @apply = apply
        @registry = registry
        @trail = trail
        @now = now
      end

      def call
        check!
        states = trail.rule_states(@at)
        loaded = Runtime.store.load
        entries = targets(states, loaded).map { |target| entry(target, states, loaded) }
        report(entries)
      rescue Failure => e
        Result.failure(e.code, e.message)
      rescue Runtime::StoreError => e
        Reporting.report(e, operation: "restore")
        Result.failure(:store_error, e.message)
      end

      private

      attr_reader :registry

      def check!
        raise Failure.new(:invalid, "a reason is required") unless @reason.is_a?(String) && !@reason.strip.empty?
        raise Failure.new(:invalid, "at: must be a Time") unless @at.is_a?(Time)
        raise Failure.new(:invalid, "at: #{@at.utc.iso8601} is in the future") if @at > @now
        raise Failure.new(:runtime_rules_off, "runtime rules are off; set config.runtime_rules = true first") unless Runtime.enabled?

        oldest = @now - StandardFlags.config.membership_retention
        if @at < oldest
          raise Failure.new(:retention_exceeded, "at: #{@at.utc.iso8601} is older than config.membership_retention " \
                                                 "(#{oldest.utc.iso8601}); removed memberships before then may be purged")
        end
        return if @trail || StandardFlags::AuditTrail.available?

        raise Failure.new(:audit_unavailable, "restore reads rule history from standard_audit's audit_logs, " \
                                              "and standard_audit is not loaded")
      end

      def trail
        @trail ||= StandardFlags::AuditTrail.new
      end

      # "cohort:<key>" Strings, then flag keys (Symbols): the ones asked for,
      # else every cohort and every rule with history or a row. Cohorts go
      # first, so their members are back before any flag that attaches them
      # serves again.
      def targets(states, loaded)
        return Array(@keys).map { |key| target(key) }.uniq.partition { |t| t.is_a?(String) }.flatten(1) if @keys

        loaded.cohorts.map { |cohort| "cohort:#{cohort.key}" }.sort + (states.keys + loaded.rules.map(&:key)).uniq.sort
      end

      def target(key)
        key.to_s.start_with?("cohort:") ? key.to_s : key.to_s.to_sym
      end

      def entry(target, states, loaded)
        return cohort_entry(target, loaded) if target.is_a?(String)

        skip = skip_reason(target) || (NO_HISTORY unless states[target])
        return Entry.new(target: target.to_s, status: "skipped", changes: [], notes: [ skip ], error: nil) if skip

        rule = loaded.rules.find { |r| r.key == target }
        past = plain(states[target])
        notes = []
        plan = rule_plan(target, past, rule, notes) + member_plan({ rule: target }, notes)
        bucketing = { salt: past["salt"], hash_version: past["hash_version"] } unless rule
        run(target, plan, notes, revision: rule&.lock_version, bucketing: bucketing)
      end

      def cohort_entry(target, loaded)
        key = target.delete_prefix("cohort:")
        unless loaded.cohorts.any? { |cohort| cohort.key == key }
          return Entry.new(target: target, status: "skipped", changes: [], notes: [ "cohort does not exist now" ], error: nil)
        end

        notes = []
        run(target, member_plan({ cohort: key }, notes), notes, revision: nil, bucketing: nil)
      end

      def skip_reason(key)
        return "tombstoned flag" if registry.tombstoned?(key)

        definition = registry[key]
        return "undeclared flag" unless definition

        pin = EnvPin.scan(definition, StandardFlags.config.env_source).pin
        "pinned by #{pin.var}; skipped" if pin
      end

      # -- the rule -----------------------------------------------------------

      def rule_plan(key, past, rule, notes)
        current = plain((rule || Runtime::Rule.build(key: key, salt: past["salt"], hash_version: past["hash_version"])).audit_state)
        notes << "bucketing (salt, hash version) differs and can't change; kept" if bucketing(past) != bucketing(current)
        status_plan(past, current, notes) + conditions_plan(past, current) + ramp_plan(past, current, notes) +
          variants_plan(past, current) + value_plan(past, current) + cohorts_plan(past, current)
      end

      def status_plan(past, current, notes)
        from = current["status"]
        to = past["status"]
        stop = past["stop_value"]
        return Plan.empty if from == to && (to != "stopped" || current["stop_value"] == stop)

        if from == "stopped" && to != "stopped"
          notes << "stopped now and #{to} then; operations can't un-stop a rule"
          return Plan.empty
        end

        case to
        when "running" then change("status #{from} → running", status: "running")
        when "stopped" then change("status #{from} → stopped, serving #{stop}", status: "stopped", stop_value: stop)
        else
          return change("status running → paused", status: "paused") if from == "running"

          notes << "draft and paused both serve the code default; left #{from}"
          Plan.empty
        end
      end

      def conditions_plan(past, current)
        return Plan.empty if past["conditions"] == current["conditions"]

        change("conditions #{json(current['conditions'])} → #{json(past['conditions'])}", conditions: past["conditions"])
      end

      def ramp_plan(past, current, notes)
        bps = past["percentage_bps"]
        return Plan.empty if bps == current["percentage_bps"] && past["rollout_value"] == current["rollout_value"]

        if bps.nil?
          notes << "no percentage then, #{current['percentage_bps']} bps now; operations can't clear a percentage, so it was kept"
          return Plan.empty
        end
        # As Ramp: with no rollout value then, the current one stays.
        rollout = past["rollout_value"].nil? ? current["rollout_value"] : past["rollout_value"]
        change("percentage #{bps_text(current)} → #{bps_text(past)}", percentage_bps: bps, rollout_value: rollout)
      end

      def variants_plan(past, current)
        return Plan.empty if past["variant_weights"] == current["variant_weights"]

        change("variants #{json(current['variant_weights'])} → #{json(past['variant_weights'])}",
               variant_weights: past["variant_weights"])
      end

      def value_plan(past, current)
        return Plan.empty if past["fallthrough_value"] == current["fallthrough_value"]

        change("fallthrough #{current['fallthrough_value'] || '-'} → #{past['fallthrough_value'] || '-'}",
               fallthrough_value: past["fallthrough_value"])
      end

      # The attachments exactly as they were, order included.
      def cohorts_plan(past, current)
        return Plan.empty if past["cohorts"] == current["cohorts"]

        before = current["cohorts"].to_h { |a| [ a["cohort"], a["value"] ] }
        after = past["cohorts"].to_h { |a| [ a["cohort"], a["value"] ] }
        summaries = (before.keys - after.keys).map { |cohort| "detach cohort #{cohort}" } +
                    after.reject { |cohort, value| before[cohort] == value }.map { |cohort, value| "attach cohort #{cohort} → #{value}" }
        summaries << "cohort order #{before.keys.join(', ')} → #{after.keys.join(', ')}" if summaries.empty?
        Plan.new(changes: summaries, attributes: { cohorts: past["cohorts"] }, remove: [], add: [])
      end

      # -- memberships -------------------------------------------------------

      # Removes the members added since T, then adds those there at T (with
      # their value and expiry). Unit keys stay inside the plan; summaries
      # carry counts.
      def member_plan(owner, notes)
        past = Runtime.store.members_at(@at, **owner).to_h { |m| [ m.unit_key, m ] }
        now = Runtime.store.members(**owner).memberships.select { |m| m.live?(@now) }.to_h { |m| [ m.unit_key, m ] }
        expired, wanted = past.values.reject { |m| same?(now[m.unit_key], m) }.partition { |m| !m.live?(@now) }
        gone = now.values.reject { |m| past.key?(m.unit_key) }
        notes << "#{expired.size} member(s) expired since then; not restored" unless expired.empty?
        remove_plan(gone) + add_plan(owner, wanted)
      end

      def same?(current, past)
        current && current.value == past.value && current.expires_at&.to_i == past.expires_at&.to_i
      end

      def remove_plan(memberships)
        memberships.group_by(&:unit).map do |unit, group|
          Plan.new(changes: [ "members −#{group.size} (#{unit})" ], attributes: {},
                   remove: [ { unit: unit, keys: group.map(&:unit_key) } ], add: [])
        end.reduce(Plan.empty, :+)
      end

      def add_plan(owner, memberships)
        memberships.group_by { |m| [ m.unit, m.value, m.expires_at ] }.map do |(unit, value, expires_at), group|
          Plan.new(changes: [ "members +#{group.size} (#{unit}#{" → #{value}" if owner[:rule]})" ], attributes: {}, remove: [],
                   add: [ { unit: unit, keys: group.map(&:unit_key), value: value, expires_at: expires_at } ])
        end.reduce(Plan.empty, :+)
      end

      # -- running the plan --------------------------------------------------

      # Plans, or with apply: writes, one target's state at T in one write.
      def run(target, plan, notes, revision:, bucketing:)
        name = target.to_s
        return Entry.new(target: name, status: "unchanged", changes: [], notes: notes, error: nil) if plan.changes.empty?
        return Entry.new(target: name, status: "planned", changes: plan.changes, notes: notes, error: nil) unless @apply

        args = { attributes: plan.attributes, remove: plan.remove, add: plan.add, restored_to: @at.utc.iso8601 }
        args[:bucketing] = bucketing if bucketing
        result = RestoreTarget.call(target, actor: ACTOR, reason: "restore to #{@at.utc.iso8601}: #{@reason}",
                                            expected_revision: revision, registry: registry, **args)
        return Entry.new(target: name, status: "applied", changes: plan.changes, notes: notes, error: nil) if result.success?

        Entry.new(target: name, status: "failed", changes: [], notes: notes + [ "nothing was changed; not applied: #{plan.changes.join('; ')}" ],
                  error: "#{result.code}: #{result.errors.join('; ')}")
      end

      def report(entries)
        value = { at: @at.utc.iso8601, applied: @apply, entries: entries.map(&:to_h) }
        failed = entries.select { |e| e.status == "failed" }
        return Result.success(value) if failed.empty?

        Result.new(success: false, value: value, code: :partial_failure,
                   errors: failed.map { |e| "#{e.target}: #{e.error}" })
      end

      # -- helpers -----------------------------------------------------------

      def change(summary, **attributes)
        Plan.new(changes: [ summary ], attributes: attributes, remove: [], add: [])
      end

      # String keys, JSON values: audit metadata and live state compare equal.
      def plain(state)
        JSON.parse(JSON.generate(state))
      end

      def bucketing(state)
        state.values_at("salt", "hash_version")
      end

      def bps_text(state)
        bps = state["percentage_bps"]
        bps.nil? ? "-" : "#{bps} bps#{" → #{state['rollout_value']}" if state['rollout_value']}"
      end

      def json(value)
        JSON.generate(value)
      end
    end
  end
end
