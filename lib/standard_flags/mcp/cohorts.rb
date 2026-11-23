module StandardFlags
  module MCP
    # Shared by the cohort tools.
    module CohortView
      private

      # The flags it is attached to are those the actor may read; the rest
      # are counted in `hidden_flags`.
      def cohort_summary(cohort)
        attached = loaded.rules.filter_map do |rule|
          value = rule.cohort_attachments.find { |key, _| key == cohort.key }&.last
          { key: rule.key, value: value } if value
        end
        readable, hidden = attached.partition { |a| allowed?("flags:read", a[:key]) }
        cohort.audit_state.merge(archived: cohort.archived?, attached_to: readable.sort_by { |a| a[:key] },
                                 hidden_flags: hidden.size)
      end

      def runtime!
        raise ToolError.new(:runtime_rules_off, "runtime rules are off") unless Runtime.enabled?
      end
    end

    # Every cohort the actor may read, with its unit, member count and the
    # flags it is attached to.
    class ListCohorts < Tool
      include CohortView

      tool_name "list_cohorts"
      description "List cohorts (named member lists): unit, member count, archived state and the flags each is attached to."
      schema({ include_archived: { type: "boolean", description: "Include archived cohorts (default false)" } })

      private

      def perform(args)
        runtime!
        cohorts = loaded.cohorts.sort_by(&:key)
        cohorts = cohorts.reject(&:archived?) unless args["include_archived"] == true
        { cohorts: cohorts.select { |cohort| allowed?("flags:read", "cohort:#{cohort.key}") }.map { |c| cohort_summary(c) },
          store_revision: store_revision }
      end
    end

    # One cohort. Its members are listed by list_members (cohort:).
    class GetCohort < Tool
      include CohortView

      tool_name "get_cohort"
      description "Show one cohort: name, description, unit, member count, archived state and attached flags."
      schema({ cohort: { type: "string", description: "The cohort key" } }, required: %w[cohort])

      private

      def perform(args)
        key = args["cohort"].to_s.delete_prefix("cohort:")
        authorize!("flags:read", "cohort:#{key}")
        runtime!
        cohort = loaded.cohorts.find { |candidate| candidate.key == key }
        raise ToolError.new(:unknown_cohort, "unknown cohort #{key.inspect}") unless cohort

        cohort_summary(cohort).merge(store_revision: store_revision)
      end
    end
  end
end
