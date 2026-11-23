module StandardFlags
  module Tooling
    # `flags:show KEY=`: one flag's declaration, its value here, any ENV pin,
    # and its stored rule (read fresh from the store, not the cache).
    # `KEY=cohort:<key>` shows a cohort.
    class Show
      def initialize(key, registry: StandardFlags.registry, store: nil)
        @key = key.to_s
        @registry = registry
        @store = store
      end

      def render
        return cohort_lines.join("\n") if @key.start_with?("cohort:")

        definition = @registry[@key]
        return "unknown flag :#{@key}" unless definition

        evaluation = Evaluator.evaluate(@registry, definition.key, Context.empty)
        lines = [ "#{definition.key} (#{definition.kind}, owner: #{definition.owner}#{", unit: #{definition.unit}" if definition.unit})",
                  "  value here: #{evaluation.value.inspect} (#{evaluation.reason}#{", #{evaluation.rule_id}" if evaluation.rule_id})" ]
        pin = EnvPin.scan(definition, StandardFlags.config.env_source).pin
        lines << "  pinned by #{pin.var}: operations refuse to change it" if pin
        lines.concat(rule_lines(definition)).join("\n")
      end

      private

      def store
        @store || Runtime.store
      end

      def rule_lines(definition)
        return [ "  runtime rules are off" ] unless Runtime.enabled?

        loaded = store.load
        rule = loaded.rules.find { |r| r.key == definition.key }
        return [ "  rule: none (store revision #{store.revision || "none"})" ] unless rule

        [ "  rule: #{rule.status}, revision #{rule.lock_version} (store revision #{store.revision || "none"})",
          "  percentage: #{rule.percentage_bps.nil? ? '-' : "#{rule.percentage_bps} bps"}" \
          "#{" → #{rule.rollout_value}" if rule.rollout_value}#{", full since #{rule.full_since.utc.iso8601}" if rule.full_since}",
          "  variants: #{rule.variant_weights.empty? ? '-' : rule.variant_weights.map { |v, w| "#{v} #{w}" }.join(', ')}",
          "  fallthrough: #{rule.fallthrough_value || '-'}  stop value: #{rule.stop_value || '-'}",
          "  conditions: #{rule.conditions.empty? ? '-' : JSON.generate(rule.conditions)}",
          "  cohorts: #{rule.cohort_attachments.empty? ? '-' : rule.cohort_attachments.map { |k, v| "#{k} → #{v}" }.join(', ')}",
          "  members: #{rule.member_count}",
          "  last evaluated: #{rule.last_evaluated_at&.utc&.iso8601 || '-'}" ]
      rescue StandardError => e
        [ "  rule: could not read the store (#{(e.cause_class if e.is_a?(Runtime::StoreError)) || e.class})" ]
      end

      def cohort_lines
        key = @key.delete_prefix("cohort:")
        return [ "runtime rules are off" ] unless Runtime.enabled?

        loaded = store.load
        cohort = loaded.cohorts.find { |c| c.key == key }
        return [ "unknown cohort #{key.inspect}" ] unless cohort

        attached = loaded.rules.select { |rule| rule.cohort_attachments.any? { |k, _| k == key } }.map(&:key).sort
        [ "cohort #{key} (unit: #{cohort.unit}#{", archived #{cohort.archived_at.utc.iso8601}" if cohort.archived?})",
          ("  #{cohort.name}" if cohort.name), ("  #{cohort.description}" if cohort.description),
          "  members: #{cohort.member_count}",
          "  attached to: #{attached.empty? ? '-' : attached.map { |k| ":#{k}" }.join(', ')}" ].compact
      end
    end

    # The rake tasks that change flags. Each needs REASON= and runs as
    # `StandardFlags::Actor.system("rake")`; it prints the outcome and the
    # new revision.
    class Command
      ACTOR = Actor.system("rake")
      Outcome = Data.define(:ok, :message) do
        alias_method :ok?, :ok
      end

      def initialize(env, registry: StandardFlags.registry)
        @env = env
        @registry = registry
      end

      def run(task)
        reason = fetch("REASON")
        return refuse(task, "REASON= is required (it is written to the audit log)") unless reason
        return purge(reason) if task == :purge

        key = fetch("KEY")
        return refuse(task, "KEY= is required") unless key

        operation, args = operation_for(task)
        report(task, key, operation.call(key, actor: ACTOR, reason: reason, registry: @registry, **args))
      rescue ArgumentError => e
        refuse(task, e.message)
      end

      private

      def operation_for(task)
        case task
        when :set then [ Operations::SetValue, { value: required("VALUE") } ]
        when :ramp then [ Operations::Ramp, { bps: Integer(required("BPS"), 10), **optional("VALUE" => :value) } ]
        when :start then [ Operations::Start, {} ]
        when :pause then [ Operations::Pause, {} ]
        when :stop then [ Operations::Stop, { serve: required("SERVE") } ]
        when :members_add
          [ Operations::AddMembers, { keys: keys, **optional("UNIT" => :unit, "VALUE" => :value, "EXPIRES_AT" => :expires_at) } ]
        when :members_remove then [ Operations::RemoveMembers, { keys: keys, **optional("UNIT" => :unit) } ]
        else raise ArgumentError, "unknown task #{task.inspect}"
        end
      end

      def purge(reason)
        return refuse(:purge, "runtime rules are off") unless Runtime.enabled?

        counts = Runtime.purge!
        Reporting.instrument(:purge_requested, actor: ACTOR.to_s, reason: reason, **counts)
        Outcome.new(ok: true, message: "flags:purge: deleted #{counts[:removed]} removed and #{counts[:expired]} expired memberships")
      rescue StandardError => e
        refuse(:purge, "could not purge (#{(e.cause_class if e.is_a?(Runtime::StoreError)) || e.class})")
      end

      def report(task, key, result)
        name = "flags:#{task.to_s.tr('_', ':')} #{key}"
        return refuse_result(name, result) unless result.success?

        value = result.value
        state = value[:rule] || value[:state]
        details = [ ("status #{state[:status]}" if state&.key?(:status)), *value.slice(:added, :updated, :removed).map { |k, v| "#{v} #{k}" } ]
        Outcome.new(ok: true, message: "#{name}: ok, revision #{value[:revision]}#{" (#{details.compact.join(', ')})" unless details.compact.empty?}")
      end

      def refuse_result(name, result)
        Outcome.new(ok: false, message: "#{name}: refused (#{result.code}): #{result.errors.join('; ')}")
      end

      def refuse(task, message)
        Outcome.new(ok: false, message: "flags:#{task.to_s.tr('_', ':')}: #{message}")
      end

      def keys
        required("KEYS").split(",").map(&:strip)
      end

      def fetch(name)
        value = @env[name]
        value unless value.nil? || value.strip.empty?
      end

      def required(name)
        fetch(name) || raise(ArgumentError, "#{name}= is required")
      end

      def optional(names)
        names.each_with_object({}) { |(var, arg), out| (value = fetch(var)) && out[arg] = value }
      end
    end
  end
end
