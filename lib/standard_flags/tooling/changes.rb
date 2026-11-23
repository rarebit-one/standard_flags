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
    # `StandardFlags::Actor.system("rake")`; it prints the outcome, the new
    # revision, "started" when the change started a draft rule, and any
    # warnings.
    class Command
      ACTOR = Actor.system("rake")
      # How an AT= ends: Z or an offset. A bare local time would be read in
      # the server's zone, which may not be the operator's, so it is refused.
      ZONED = /(?:Z|[+-]\d\d:?\d\d)\z/i
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
        return restore(reason) if task == :restore

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

      # Prints the plan (a dry run unless APPLY=1), member changes as counts.
      def restore(reason)
        at = iso8601(required("AT"))
        return refuse(:restore, "AT= must be an ISO 8601 time with a zone (Z or an offset), e.g. 2026-11-20T09:00:00Z") unless at

        keys = fetch("KEYS")&.split(",")&.map(&:strip)
        result = Operations::Restore.call(at: at, reason: reason, keys: keys, apply: @env["APPLY"] == "1", registry: @registry)
        return refuse_result("flags:restore", result) if result.value.nil?

        Outcome.new(ok: result.success?, message: restore_lines(result).join("\n"))
      end

      def restore_lines(result)
        value = result.value
        lines = [ "flags:restore to #{value[:at]} (#{value[:applied] ? 'applied' : 'dry run; APPLY=1 applies it'})" ]
        value[:entries].each do |entry|
          changes = entry[:changes].empty? ? "" : ": #{entry[:changes].join('; ')}"
          lines << "  #{entry[:target]}: #{entry[:status]}#{changes}"
          lines << "    error: #{entry[:error]}" if entry[:error]
          entry[:notes].each { |note| lines << "    note: #{note}" }
        end
        lines << "  nothing to restore" if value[:entries].empty?
        lines << "flags:restore: #{result.errors.size} failed (#{result.code})" unless result.success?
        lines
      end

      def report(task, key, result)
        name = "flags:#{task.to_s.tr('_', ':')} #{key}"
        return refuse_result(name, result) unless result.success?

        value = result.value
        state = value[:rule] || value[:state]
        details = [ ("status #{state[:status]}" if state&.key?(:status)), ("started" if value[:started]),
                    *value.slice(:added, :updated, :removed).map { |k, v| "#{v} #{k}" } ]
        lines = [ "#{name}: ok, revision #{value[:revision]}#{" (#{details.compact.join(', ')})" unless details.compact.empty?}" ]
        Outcome.new(ok: true, message: (lines + result.warnings.map { |w| "  warning: #{w}" }).join("\n"))
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

      # nil unless it names its zone (ZONED).
      def iso8601(text)
        Time.iso8601(text) if text.strip.match?(ZONED)
      rescue ArgumentError
        nil
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
