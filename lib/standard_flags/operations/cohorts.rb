module StandardFlags
  module Operations
    # Shared by the cohort operations: they take a cohort key ("staff" or
    # "cohort:staff") and check `expected_revision` against the store's
    # revision, since cohorts have no lock_version of their own; `revision`
    # in their Results is that number too. The state row is locked last, as
    # in every write.
    class CohortOperation < Base
      def self.targets
        %i[cohort]
      end

      private

      def parse_target!
        @target = "cohort:#{@target.to_s.delete_prefix('cohort:')}"
        super
      end

      def run
        cohort = tx.lock_cohort(@cohort_key)
        before = cohort&.audit_state
        cohort, extra = perform(cohort)
        check_revision!(tx.lock_revision)
        revision = Runtime.bump_revision!(tx)
        publish(event, { cohort: @cohort_key, before: before, after: cohort.audit_state,
                         revision: revision, store_revision: revision, **extra })
        { cohort: @cohort_key, state: cohort.audit_state, revision: revision, store_revision: revision, **extra }
      end
    end

    # Creates a named member list of one unit (`unit:`), with optional
    # `name:` and `description:`. A taken key fails with :already_exists,
    # including when a concurrent CreateCohort took it first.
    class CreateCohort < CohortOperation
      arguments required: %i[unit], optional: %i[name description]

      private

      def event = Events::COHORT_EVENTS[:created]

      def perform(existing)
        already_exists! if existing

        unit = registry.units[arg(:unit).to_s.to_sym]
        raise Failure.new(:invalid, "unknown unit #{arg(:unit).inspect}") unless unit

        created = tx.create_cohort(@cohort_key, unit: unit.name.to_s, name: arg(:name)&.to_s, description: arg(:description)&.to_s)
        already_exists! unless created
        [ created, {} ]
      end

      def already_exists!
        raise Failure.new(:already_exists, "cohort #{@cohort_key.inspect} already exists")
      end
    end

    # Archives a cohort: no new members, and rules ignore it. Detach it from
    # every flag first.
    class ArchiveCohort < CohortOperation
      arguments

      private

      def event = Events::COHORT_EVENTS[:archived]

      def perform(cohort)
        raise Failure.new(:invalid, "cohort #{@cohort_key.inspect} does not exist") unless cohort
        raise Failure.new(:invalid, "cohort #{@cohort_key.inspect} is already archived") if cohort.archived?

        attached = tx.rules_attached_to(@cohort_key)
        unless attached.empty?
          raise Failure.new(:invalid, "cohort #{@cohort_key.inspect} is attached to #{attached.map { |k| ":#{k}" }.join(', ')}; detach it first")
        end

        [ tx.save_cohort(cohort, archived_at: Time.now.utc), {} ]
      end
    end
  end
end
