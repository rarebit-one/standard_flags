require "time"

module StandardFlags
  module Operations
    # Restore's write: one flag's rule (its settings, attached cohorts and
    # direct members) or one cohort's members, put back as a whole in one
    # store write, with one revision bump and one audit row
    # (`standard_flags.flag.restored` or `standard_flags.cohort.restored`:
    # the full state before and after, member changes as counts). Evaluators
    # see the state before or the state after, never one in between, and a
    # failure changes nothing.
    #
    # Inside the write, members are removed before any are added, so
    # `config.max_members` is checked against the end state; the
    # per-operation key limit doesn't apply (keys go to the store in chunks
    # of it). Unit keys are the store's own (`normalized: true`), never
    # passed through the unit's `key:` again.
    #
    # Its arguments are Restore's plan: `attributes:` (rule columns, in
    # their stored form), `remove:` and `add:` (groups of unit keys, each
    # `{ unit:, keys: }`, adds also `value:` and `expires_at:`),
    # `bucketing:` (salt and hash version, for a rule created again) and
    # `restored_to:` (T, ISO 8601). Only Restore calls it; it is not an MCP
    # tool.
    #
    # @api private
    class RestoreTarget < Base
      include MemberKeys

      STATUSES = %w[draft paused running stopped].freeze
      ATTRIBUTES = %i[status stop_value conditions percentage_bps rollout_value variant_weights fallthrough_value cohorts].freeze

      arguments optional: %i[attributes remove add bucketing restored_to]

      def self.targets
        %i[flag cohort]
      end

      def self.operation_name
        "restore"
      end

      private

      def event
        (@cohort_key ? Events::COHORT_EVENTS : Events::FLAG_EVENTS)[:restored]
      end

      def sensitive?
        true
      end

      def run
        @cohort_key ? run_cohort : super
      end

      def attributes
        (arg(:attributes) || {}).transform_keys(&:to_sym)
      end

      # A rule created again keeps the salt and hash version it had at T.
      def bucketing
        given = arg(:bucketing)
        return super unless given

        { salt: given[:salt], hash_version: given[:hash_version] }
      end

      # Every cohort the rule ends up attaching, so the check below can read
      # them (locked after the rule, as every write does).
      def extra_cohort_keys
        (attributes[:cohorts] || @rule.cohorts).filter_map { |a| a["cohort"] if a.is_a?(Hash) }
      end

      # Members first (removals, then additions), then every column in one
      # save. Base re-checks a running rule; any other is checked here, as
      # the operations that set each column would have.
      def perform
        members = restore_members(@rule) { validate.unit!(definition, registry, "members") }
        save!(rule_attributes)
        validate.conditions_size!(@rule.conditions, config)
        validate.rule!(definition, @rule, registry, @cohorts) unless @rule.running?
        { restored_to: arg(:restored_to), members: members }
      end

      def rule_attributes
        unknown = attributes.keys - ATTRIBUTES
        raise Failure.new(:invalid, "unknown rule attribute(s): #{unknown.join(', ')}") unless unknown.empty?

        attributes.to_h { |name, value| [ name, column(name, value) ] }.merge(full_since_for(attributes))
      end

      def column(name, value)
        case name
        when :status then status!(value)
        when :conditions then conditions!(value)
        when :percentage_bps then value.nil? ? nil : validate.bps!(value)
        when :variant_weights then value.nil? || value.empty? ? {} : validate.weights!(definition, value)
        when :cohorts then attachments!(value)
        else value.nil? ? nil : validate.value!(definition, value, name.to_s)
        end
      end

      def status!(status)
        status = status.to_s
        raise Failure.new(:invalid, "status #{status.inspect} is not one of #{STATUSES.join('/')}") unless STATUSES.include?(status)
        raise Failure.new(:invalid, ":#{@key} is stopped; operations can't un-stop a rule") if @rule.stopped? && status != "stopped"

        status
      end

      def conditions!(conditions)
        raise Failure.new(:invalid, "conditions must be a Hash") unless conditions.is_a?(Hash)

        conditions
      end

      def attachments!(attachments)
        list = Array(attachments).map do |a|
          a = a.to_h.transform_keys(&:to_s)
          { "cohort" => a["cohort"].to_s, "value" => validate.value!(definition, a["value"], "cohort #{a['cohort']}'s value") }
        end
        if list.size > config.max_cohorts_per_rule
          raise Failure.new(:limit_exceeded, ":#{@key} would have #{list.size} cohorts; the limit is #{config.max_cohorts_per_rule}")
        end

        list
      end

      # As Ramp sets it: reaching 10,000 keeps (or starts) full_since.
      def full_since_for(attributes)
        return {} unless attributes.key?(:percentage_bps)

        { full_since: attributes[:percentage_bps] == Bucket::BUCKETS ? (@rule.full_since || Time.now.utc) : nil }
      end

      # Locks the cohort, then its memberships, then (last, as every write
      # does) the state row for the revision check.
      def run_cohort
        cohort = tx.lock_cohort(@cohort_key)
        raise Failure.new(:invalid, "cohort #{@cohort_key.inspect} does not exist") unless cohort
        raise Failure.new(:invalid, "cohort #{@cohort_key.inspect} is archived") if cohort.archived? && groups(:add).any?

        before = cohort.audit_state
        members = restore_members(cohort) do
          registry.units[cohort.unit] ||
            raise(Failure.new(:invalid, "cohort #{@cohort_key.inspect} holds :#{cohort.unit}, which is not declared"))
        end
        cohort = tx.save_cohort(cohort, {})
        check_revision!(tx.lock_revision)
        revision = Runtime.bump_revision!(tx)
        extra = { restored_to: arg(:restored_to), members: members }
        publish(event, { cohort: @cohort_key, before: before, after: cohort.audit_state,
                         revision: revision, store_revision: revision, **extra })
        { cohort: @cohort_key, state: cohort.audit_state, revision: revision, store_revision: revision, **extra }
      end

      # Removals, then additions, then the limit on the end state. Yields
      # for the owner's unit only when there are members to change.
      def restore_members(owner)
        counts = { removed: 0, added: 0, updated: 0 }
        return counts if groups(:remove).empty? && groups(:add).empty?

        unit = yield
        groups(:remove).each do |group|
          chunks(unit, group).each { |keys| counts[:removed] += tx.remove_members(owner, unit: unit.name, unit_keys: keys) }
        end
        groups(:add).each do |group|
          value = @cohort_key ? "on" : validate.value!(definition, group[:value], "value")
          expires_at = validate.expires_at!(group[:expires_at], Time.now.utc)
          chunks(unit, group).each do |keys|
            tx.upsert_members(owner, unit: unit.name, unit_keys: keys, value: value, expires_at: expires_at)
              .each { |name, count| counts[name] += count }
          end
        end
        validate.members_count!(tx.count_members(owner, now: Time.now.utc), owner_name, config) if groups(:add).any?
        counts
      end

      def groups(name)
        Array(arg(name)).map { |group| group.to_h.transform_keys(&:to_sym) }
      end

      def chunks(unit, group)
        if group[:unit].to_s != unit.name.to_s
          raise Failure.new(:invalid, "unit: #{group[:unit].inspect} does not match :#{unit.name}")
        end

        member_keys(unit, group[:keys], normalized: true, limit: false).each_slice(config.max_keys_per_operation)
      end

      def owner_name
        @cohort_key ? "cohort #{@cohort_key.inspect}" : ":#{@key}"
      end
    end
  end
end
