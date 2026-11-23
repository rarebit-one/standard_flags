require "standard_flags/operations/failure"
require "standard_flags/operations/validation"
require "standard_flags/operations/audit"
require "standard_flags/operations/base"
require "standard_flags/operations/rules"
require "standard_flags/operations/members"
require "standard_flags/operations/cohorts"

module StandardFlags
  # The write path for runtime rules. Every change to a rule, cohort or
  # membership goes through one of these, and nothing else writes the
  # tables:
  #
  #   ops = StandardFlags::Operations
  #   ops::Ramp.call(:new_checkout, bps: 500, actor: current_user, reason: "1% canary")
  #   ops::SetValue.call(:strict_gates, value: :sensor, actor: current_user, reason: "observe first")
  #   ops::AddMembers.call(:new_checkout, keys: [ org ], value: true, actor: current_user, reason: "pilot")
  #   ops::AddMembers.call("cohort:staff", keys: staff, actor: current_user, reason: "new hires")
  #
  # Each is called as `.call(key_or_cohort, actor:, reason:, expected_revision: nil, **args)` and
  # returns a StandardFlags::Result. See Base for the steps every one takes.
  module Operations
    SCOPES = %w[flags:read flags:write flags:ramp].freeze

    # Names a cohort where an operation takes a flag key or a cohort, for
    # example `AddMembers.call(Operations.cohort(:staff), ...)`. The string
    # "cohort:staff" works too.
    CohortRef = Data.define(:key) do
      def to_s
        "cohort:#{key}"
      end
    end

    def self.cohort(key)
      CohortRef.new(key: key.to_s)
    end

    ALL = [ Start, Pause, Stop, Ramp, SetVariants, SetValue, SetConditions, AddMembers, RemoveMembers,
            CreateCohort, ArchiveCohort, AttachCohort, DetachCohort ].freeze
  end
end
