module StandardFlags
  module Operations
    # Unit keys as an operation stores them: each normalised through the
    # registry's unit (`key:`), so records and raw keys both work, or, for
    # keys already read back from the store (`normalized: true`), taken as
    # they are, since a `key:` written for records can't take its own
    # output. Checked for blanks, and (unless `limit: false`, for a write
    # that chunks them itself) against `config.max_keys_per_operation`;
    # errors never quote a key.
    module MemberKeys
      private

      def member_keys(unit, items, normalized:, limit: true)
        items = items.respond_to?(:to_ary) ? items.to_ary : [ items ]
        validate.keys_count!(items.size, config) if limit
        keys = normalized ? items.map { |item| stored_key(item) } : items.map { |item| normalize(unit, item) }
        blank = keys.count(&:nil?)
        raise Failure.new(:invalid, "#{blank} of the keys #{blank == 1 ? 'is' : 'are'} blank") unless blank.zero?
        raise Failure.new(:invalid, "keys must not be empty") if keys.empty?

        keys.uniq
      end

      def normalize(unit, item)
        unit.key_for(item)
      rescue StandardError => e
        raise Failure.new(:invalid, "a key could not be normalised for :#{unit.name} (#{e.class})")
      end

      def stored_key(item)
        raise Failure.new(:invalid, "normalized keys must be Strings") unless item.is_a?(String)

        item.strip.empty? ? nil : item
      end
    end

    # Shared by AddMembers and RemoveMembers: the owner is a flag's rule or
    # a cohort, and unit keys go through MemberKeys. `normalized: true`
    # (keys exactly as the store holds them) is internal: only a system
    # actor may pass it, and no MCP tool or admin page does. Unit keys are
    # written raw but never appear in a Result, an audit row, a
    # notification or a report: those carry the unit, the value and counts
    # only.
    class MembershipOperation < Base
      include MemberKeys

      def self.targets
        %i[flag cohort]
      end

      private

      def event
        (@cohort_key ? Events::COHORT_EVENTS : Events::FLAG_EVENTS)[self.class::VERB]
      end

      def sensitive?
        true
      end

      def run
        @cohort_key ? run_cohort : super
      end

      # Rule owners go through Base#run.
      def perform
        unit = validate.unit!(definition, registry, "members")
        change(@rule, unit).tap { save!({}) }
      end

      # Locks the cohort, then its memberships, then (last, as every write
      # does) the state row for the revision check.
      def run_cohort
        cohort = tx.lock_cohort(@cohort_key)
        raise Failure.new(:invalid, "cohort #{@cohort_key.inspect} does not exist") unless cohort
        raise Failure.new(:invalid, "cohort #{@cohort_key.inspect} is archived") if cohort.archived? && self.class::VERB == :members_added

        before = cohort.audit_state
        unit = registry.units[cohort.unit]
        raise Failure.new(:invalid, "cohort #{@cohort_key.inspect} holds :#{cohort.unit}, which is not declared") unless unit

        extra = change(cohort, unit)
        cohort = tx.save_cohort(cohort, {})
        check_revision!(tx.lock_revision)
        revision = Runtime.bump_revision!(tx)
        publish(event, { cohort: @cohort_key, before: before, after: cohort.audit_state,
                         revision: revision, store_revision: revision, **extra })
        { cohort: @cohort_key, state: cohort.audit_state, revision: revision, store_revision: revision, **extra }
      end

      def unit_keys(unit)
        if args.key?(:unit) && args[:unit].to_s != unit.name.to_s
          raise Failure.new(:invalid, "unit: #{args[:unit].inspect} does not match :#{unit.name}")
        end

        member_keys(unit, arg(:keys), normalized: normalized?)
      end

      def normalized?
        return false unless args.key?(:normalized)
        raise Failure.new(:invalid, "normalized: must be true or false") unless [ true, false ].include?(arg(:normalized))
        raise Failure.new(:invalid, "normalized: is for system actors only") if arg(:normalized) && !actor.is_a?(Actor)

        arg(:normalized)
      end
    end

    # Adds units (records or keys) to a flag's rule or a cohort, serving
    # `value:` (a flag's value; on/off flags default to on, and cohort
    # members always store "on", since the attachment decides what a cohort
    # serves). Optional `expires_at:` (a future Time). Adding a unit that is
    # already a member changes its value and expiry (the old row is kept,
    # removed, for Restore).
    class AddMembers < MembershipOperation
      VERB = :members_added
      arguments required: %i[keys], optional: %i[unit value expires_at normalized]

      private

      def change(owner, unit)
        keys = unit_keys(unit)
        value = member_value
        expires_at = validate.expires_at!(arg(:expires_at), Time.now.utc)
        counts = tx.upsert_members(owner, unit: unit.name, unit_keys: keys, value: value, expires_at: expires_at)
        validate.members_count!(tx.count_members(owner, now: Time.now.utc), owner_name, config)
        { unit: unit.name.to_s, value: value, expires_at: expires_at&.iso8601, requested: keys.size, **counts }
      end

      def member_value
        if @cohort_key
          raise Failure.new(:invalid, "cohort members serve the attachment's value; leave out value:") if args.key?(:value)

          return "on"
        end
        unless args.key?(:value)
          return "on" if definition.boolean?

          raise Failure.new(:invalid, ":#{@key} is a #{definition.kind}; pass value:")
        end
        validate.value!(definition, arg(:value), "value")
      end

      def owner_name
        @cohort_key ? "cohort #{@cohort_key.inspect}" : ":#{@key}"
      end
    end

    # Removes units (records or keys) from a flag's rule or a cohort. The
    # rows are kept, marked removed_at, until `flags:purge` deletes them
    # after `config.membership_retention`.
    class RemoveMembers < MembershipOperation
      VERB = :members_removed
      arguments required: %i[keys], optional: %i[unit normalized]

      private

      def change(owner, unit)
        keys = unit_keys(unit)
        removed = tx.remove_members(owner, unit: unit.name, unit_keys: keys)
        { unit: unit.name.to_s, requested: keys.size, removed: removed }
      end
    end
  end
end
