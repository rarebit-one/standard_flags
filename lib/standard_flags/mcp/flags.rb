module StandardFlags
  module MCP
    # What decided an evaluation, in one word.
    module Source
      module_function

      def of(evaluation)
        if evaluation.source_env_var then "env_pin"
        elsif evaluation.rule_id then "runtime_rule"
        elsif evaluation.reason == Reason::DISABLED then "guard"
        elsif evaluation.reason == Reason::ERROR then "error"
        elsif evaluation.reason == Reason::STATIC then "test_override"
        else "code_default"
        end
      end
    end

    # Every declared flag the actor may read: its declaration, its value with
    # no unit, any ENV pin, and a summary of its stored rule.
    class ListFlags < Tool
      tool_name "list_flags"
      description "List the declared feature flags: kind, owner, current value with no unit, " \
                  "ENV pin (variable name only) and runtime rule status."
      schema({})

      private

      def perform(_args)
        definitions = registry.definitions.sort_by(&:key)
        readable = definitions.select { |definition| allowed?("flags:read", definition.key) }
        if readable.empty? && !definitions.empty?
          raise ToolError.new(:unauthorized, "#{Actor.label(actor)} may not flags:read any flag")
        end

        { flags: readable.map { |definition| summary(definition) }, runtime_rules: Runtime.enabled?,
          store_revision: store_revision }
      end

      def summary(definition)
        evaluation = Evaluator.evaluate(registry, definition.key, evaluation_context)
        rule = rule_for(definition.key)
        {
          key: definition.key, kind: definition.kind, owner: definition.owner, description: definition.description,
          unit: definition.unit, values: definition.allowed_values.map { |value| Runtime.wire(value) },
          value: Runtime.wire(evaluation.value), reason: evaluation.reason, source: Source.of(evaluation),
          pinned: pin(definition),
          rule: rule && { status: rule.status, revision: rule.lock_version, percentage_bps: rule.percentage_bps,
                          member_count: rule.member_count }
        }
      end
    end

    # One flag: its declaration, what it evaluates to (for one unit when
    # `unit_key` is given), any ENV pin, and its stored rule in full. The
    # rule's cohorts are those the actor may read (`cohort:<key>`); the
    # rest are counted in `hidden_cohorts`.
    #
    # An evaluation for one unit says whether that unit is a member, so it
    # is a reveal: it needs "flags:write" on the flag and a `reason`, and is
    # audited as `standard_flags.flag.probed` (counts only, no key) before
    # anything is returned.
    class GetFlag < Tool
      tool_name "get_flag"
      description "Show one feature flag: declaration, evaluated value, reason, rule_id and source " \
                  "(optionally for one unit key: needs flags:write and a reason; audited), ENV pin status " \
                  "and the stored runtime rule."
      schema({ key: { type: "string", description: "The flag key, e.g. new_checkout" },
               unit: { type: "string", description: "The flag's unit (optional; must match the declaration)" },
               unit_key: { type: "string", description: "Evaluate for this unit key (needs flags:write and a reason)" },
               reason: { type: "string", description: "Why one unit is evaluated; written to the audit log" } },
             required: %w[key])

      private

      def perform(args)
        definition = definition!(args["key"])
        authorize!("flags:read", definition.key)
        evaluation, masked = evaluate(definition, args)
        {
          key: definition.key, kind: definition.kind, owner: definition.owner, description: definition.description,
          unit: definition.unit, values: definition.allowed_values.map { |value| Runtime.wire(value) },
          default: Runtime.wire(definition.default_for(registry.current_env)),
          evaluation: { unit_key: masked, value: Runtime.wire(evaluation.value), variant: evaluation.variant,
                        reason: evaluation.reason, error_code: evaluation.error_code, rule_id: evaluation.rule_id,
                        source: Source.of(evaluation) },
          pinned: pin(definition),
          runtime_rules: Runtime.enabled?,
          rule: readable_rule(rule_for(definition.key)),
          store_revision: store_revision
        }.merge(compat(definition))
      end

      # For a compat flag with `until_clients:` only: its window and, when
      # `config.track_compat` is on, its stored counts per platform.
      def compat(definition)
        return {} unless definition.compat_window?

        report = Diagnostics.compat(registry)
        entry = report[:flags].find { |flag| flag[:flag] == definition.key }
        { compat: { until_clients: entry[:until_clients], tracking: report[:tracking], error: report[:error],
                    tracking_since: entry[:tracking_since], last_flushed_at: entry[:last_flushed_at], stats: entry[:stats] } }
      end

      # The evaluation, and the unit key it was for, masked.
      def evaluate(definition, args)
        if args.key?("unit") && args["unit"].to_s != definition.unit.to_s
          raise ToolError.new(:invalid_arguments, "unit #{args['unit'].inspect} is not :#{definition.key}'s unit (#{definition.unit.inspect})")
        end
        return [ Evaluator.evaluate(registry, definition.key, evaluation_context), nil ] unless args.key?("unit_key")
        raise ToolError.new(:invalid_arguments, ":#{definition.key} has no unit, so it can't be evaluated per unit") unless definition.unit

        check_probe!(definition, args)
        key = unit_key(definition, args["unit_key"])
        evaluation = Evaluator.evaluate(registry.with_unit_key(definition.unit, key), definition.key, evaluation_context)
        audit_probe(definition, args)
        [ evaluation, MCP.mask(key) ]
      end

      def check_probe!(definition, args)
        authorize!("flags:write", definition.key)
        return if args["reason"].is_a?(String) && !args["reason"].strip.empty?

        raise ToolError.new(:invalid_arguments, "a reason is required to evaluate one unit key")
      end

      def audit_probe(definition, args)
        payload = { actor: actor.is_a?(Actor) ? nil : actor, actor_label: Actor.label(actor), reason: args["reason"],
                    key: definition.key, unit: definition.unit.to_s, probed: 1 }
        Operations::Audit.record_read(Events::FLAG_PROBED, payload)
      rescue Operations::Failure => e
        raise ToolError.new(e.code, "#{e.message}; nothing was evaluated")
      end

      def readable_rule(rule)
        state = rule_state(rule)
        return state unless state

        cohorts, hidden = Array(state[:cohorts]).partition do |attachment|
          attachment.is_a?(Hash) && allowed?("flags:read", "cohort:#{attachment['cohort']}")
        end
        state.merge(cohorts: cohorts, hidden_cohorts: hidden.size)
      end

      def unit_key(definition, given)
        key = begin
          registry.units[definition.unit].key_for(given.to_s)
        rescue StandardError => e
          raise ToolError.new(:invalid_arguments, "the unit key could not be normalised for :#{definition.unit} (#{e.class})")
        end
        key || raise(ToolError.new(:invalid_arguments, "unit_key is blank"))
      end
    end
  end
end
