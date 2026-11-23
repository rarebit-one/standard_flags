module StandardFlags
  module MCP
    # Shared by the member tools: they act on a flag's rule (`key`) or a
    # cohort (`cohort`), exactly one of them.
    module MemberTarget
      TARGET = {
        key: { type: "string", description: "The flag key (or give cohort)" },
        cohort: { type: "string", description: "The cohort key (or give key)" }
      }.freeze

      private

      # A flag key Symbol, or "cohort:<key>": what operations and the policy
      # take.
      def target(args)
        flag, cohort = args.values_at("key", "cohort")
        raise ToolError.new(:invalid_arguments, "give exactly one of key or cohort") unless flag.nil? ^ cohort.nil?

        flag ? definition!(flag).key : "cohort:#{cohort.to_s.delete_prefix('cohort:')}"
      end
    end

    # One page of a flag's or a cohort's members, unit keys masked
    # (`•••4567`). With `reveal: true` and a `reason`, an actor allowed
    # "flags:write" on the target sees the keys; the reveal is audited as
    # `standard_flags.members.revealed`, with counts only.
    class ListMembers < Tool
      include MemberTarget

      MAX_LIMIT = 200

      tool_name "list_members"
      description "List one page of a flag's or a cohort's members. Unit keys are masked unless reveal is true " \
                  "(needs flags:write and a reason; audited)."
      schema(TARGET.merge(
               offset: { type: "integer", description: "Members to skip (default 0)" },
               limit: { type: "integer", description: "Page size, 1-#{MAX_LIMIT} (default 50)" },
               reveal: { type: "boolean", description: "Show unit keys in full (needs flags:write and a reason)" },
               reason: { type: "string", description: "Why the keys are revealed; written to the audit log" }
             ))

      private

      def perform(args)
        owner = target(args)
        authorize!("flags:read", owner)
        raise ToolError.new(:runtime_rules_off, "runtime rules are off") unless Runtime.enabled?

        offset, limit = page_bounds(args)
        reveal = args["reveal"] == true
        check_reveal!(owner, args) if reveal
        page = read_page(owner, offset, limit)
        audit_reveal(owner, args, page) if reveal
        {
          **owner_field(owner), total: page.total, offset: offset, limit: limit,
          next_offset: (offset + limit if offset + limit < page.total), revealed: reveal,
          members: page.memberships.map { |membership| member(membership, reveal) }
        }
      end

      def page_bounds(args)
        offset = args.fetch("offset", 0)
        limit = args.fetch("limit", 50)
        raise ToolError.new(:invalid_arguments, "offset must be 0 or more") if offset.negative?
        raise ToolError.new(:invalid_arguments, "limit must be 1-#{MAX_LIMIT}") unless (1..MAX_LIMIT).cover?(limit)

        [ offset, limit ]
      end

      def check_reveal!(owner, args)
        authorize!("flags:write", owner)
        return if args["reason"].is_a?(String) && !args["reason"].strip.empty?

        raise ToolError.new(:invalid_arguments, "a reason is required to reveal unit keys")
      end

      def read_page(owner, offset, limit)
        Runtime.store.members(**owner_lookup(owner), offset: offset, limit: limit)
      rescue StandardError => e
        raise ToolError.new(:store_error, "could not read the store (#{(e.cause_class if e.is_a?(Runtime::StoreError)) || e.class})")
      end

      def audit_reveal(owner, args, page)
        payload = { actor: actor.is_a?(Actor) ? nil : actor, actor_label: Actor.label(actor), reason: args["reason"],
                    **owner_field(owner), units: page.memberships.map { |m| m.unit.to_s }.uniq.sort,
                    revealed: page.memberships.size, total: page.total }
        Operations::Audit.record_read(Events::MEMBERS_REVEALED, payload)
      rescue Operations::Failure => e
        raise ToolError.new(e.code, "#{e.message}; nothing was revealed")
      end

      def member(membership, reveal)
        expires_at = membership.expires_at
        { unit: membership.unit, unit_key: reveal ? membership.unit_key : MCP.mask(membership.unit_key),
          value: membership.value, expires_at: expires_at, expired: !membership.live?(Time.now.utc),
          added_at: membership.created_at }
      end

      def owner_lookup(owner)
        owner.is_a?(Symbol) ? { rule: owner } : { cohort: owner.delete_prefix("cohort:") }
      end

      def owner_field(owner)
        owner.is_a?(Symbol) ? { key: owner } : { cohort: owner.delete_prefix("cohort:") }
      end
    end

    class AddMembers < OperationTool
      include MemberTarget

      tool_name "add_members"
      description "Add units (by key) to a flag's rule or a cohort. Flag members serve value (on/off flags default " \
                  "to on); cohort members serve the cohort's attachment value. Keys never appear in the result."
      operation Operations::AddMembers
      schema(TARGET.merge(OperationTool::COMMON.except(:key)).merge(
               keys: { type: "array", items: { type: "string" }, description: "Unit keys" },
               value: { type: "string", description: "What flag members get: on/off, a mode value or a variant" },
               unit: { type: "string", description: "The unit (optional; must match)" },
               expires_at: { type: "string", description: "ISO 8601 time the memberships end (optional)" }
             ), required: %w[keys reason])

      private

      def operation_args(args)
        out = args.slice("keys", "value", "unit").transform_keys(&:to_sym)
        out[:expires_at] = expires_at(args["expires_at"]) if args.key?("expires_at")
        out
      end

      def expires_at(text)
        Time.iso8601(text.to_s)
      rescue ArgumentError
        raise ToolError.new(:invalid_arguments, "expires_at must be an ISO 8601 time")
      end
    end

    class RemoveMembers < OperationTool
      include MemberTarget

      tool_name "remove_members"
      description "Remove units (by key) from a flag's rule or a cohort. Rows are kept for " \
                  "config.membership_retention so they can be restored. Keys never appear in the result."
      operation Operations::RemoveMembers
      schema(TARGET.merge(OperationTool::COMMON.except(:key)).merge(
               keys: { type: "array", items: { type: "string" }, description: "Unit keys" },
               unit: { type: "string", description: "The unit (optional; must match)" }
             ), required: %w[keys reason])

      private

      def operation_args(args) = args.slice("keys", "unit").transform_keys(&:to_sym)
    end
  end
end
