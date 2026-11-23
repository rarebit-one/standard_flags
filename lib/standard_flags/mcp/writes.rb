module StandardFlags
  module MCP
    # A tool that runs one operation. `reason` is required and
    # `expected_revision` (the rule's revision from get_flag) optional; the
    # operation authorises, refuses pins, validates and audits, and its
    # failure code becomes the error code. A success returns the Result's
    # value, plus `warnings` when it has any.
    class OperationTool < Tool
      COMMON = {
        key: { type: "string", description: "The flag key" },
        reason: { type: "string", description: "Why; written to the audit log" },
        expected_revision: { type: "integer", description: "Refuse unless the rule is still at this revision (from get_flag)" }
      }.freeze

      class << self
        def operation(klass = nil)
          @operation = klass if klass
          @operation
        end

        # The common arguments plus the operation's own.
        def arguments(properties = {}, required: [])
          schema(COMMON.merge(properties), required: %w[key reason] + required)
        end
      end

      private

      def perform(args)
        result = self.class.operation.call(target(args), actor: actor, reason: args["reason"],
                                                         expected_revision: args["expected_revision"],
                                                         registry: registry, **operation_args(args))
        raise ToolError.new(result.code, result.errors.join("; ")) unless result.success?

        result.warnings.empty? ? result.value : result.value.merge(warnings: result.warnings)
      end

      def target(args)
        args["key"]
      end

      def operation_args(_args)
        {}
      end
    end

    class StartFlag < OperationTool
      tool_name "start_flag"
      description "Start a draft or paused runtime rule, so it serves."
      operation Operations::Start
      arguments
    end

    class PauseFlag < OperationTool
      tool_name "pause_flag"
      description "Pause a running runtime rule: the code default serves, and the rule's settings are kept."
      operation Operations::Pause
      arguments
    end

    class StopFlag < OperationTool
      tool_name "stop_flag"
      description "Stop a runtime rule, serving one value to everyone (the winner, or the flag's final value)."
      operation Operations::Stop
      arguments({ serve: { type: "string", description: "The value to serve: on/off, a mode value or a variant" } },
                required: %w[serve])

      private

      def operation_args(args) = { serve: args["serve"] }
    end

    class RampFlag < OperationTool
      tool_name "ramp_flag"
      description "Set the percentage of units (basis points, 0-10000) that get the rollout value. Needs flags:ramp."
      operation Operations::Ramp
      arguments({ bps: { type: "integer", description: "Basis points, 0-10000 (500 = 5%)" },
                  value: { type: "string", description: "The rollout value (modes and experiments; on/off flags roll out on)" } },
                required: %w[bps])

      private

      def operation_args(args) = args.slice("bps", "value").transform_keys(&:to_sym)
    end

    class SetFlagValue < OperationTool
      tool_name "set_flag_value"
      description "Set a runtime rule's fallthrough value, served to every unit nothing else matched " \
                  "(how a mode moves off → sensor → on, or a kill switch is thrown). null clears it. " \
                  "A draft rule starts (the result says started: true); a paused one stays paused, with a warning."
      operation Operations::SetValue
      arguments({ value: { type: %w[string null], description: "on/off, a mode value or a variant; null clears" } },
                required: %w[value])

      private

      def operation_args(args) = { value: args["value"] }
    end
  end
end
