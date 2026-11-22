module StandardFlags
  module Runtime
    # The process-wide view of the rules table: every rule, plus each cohort's
    # key, unit and member count (never its members). Immutable, so any
    # thread can read it while the cache swaps in a newer one.
    #
    # * revision   — standard_flags_state.revision when it was loaded.
    # * loaded     — false until a load has succeeded in this process; the
    #                resolver then defers to code defaults.
    # * stale      — the last refresh failed, so this is the last good copy.
    # * loaded_at  — wall-clock time of the last successful load.
    # * checked_at — monotonic time of the last revision check (or attempt).
    RuleSnapshot = Data.define(:revision, :rules, :cohorts, :cohorts_by_id, :loaded, :stale, :loaded_at, :checked_at) do
      def self.empty(checked_at: nil)
        new(revision: nil, rules: {}.freeze, cohorts: {}.freeze, cohorts_by_id: {}.freeze,
            loaded: false, stale: false, loaded_at: nil, checked_at: checked_at)
      end

      # `revision` is the one read just before `loaded`, so a write in between
      # only makes the next check reload again.
      def self.build(loaded, revision:, checked_at:, loaded_at: Time.now.utc)
        cohorts = loaded.cohorts.to_h { |cohort| [ cohort.key, cohort ] }.freeze
        new(
          revision: revision,
          rules: loaded.rules.to_h { |rule| [ rule.key, rule ] }.freeze,
          cohorts: cohorts,
          cohorts_by_id: cohorts.values.to_h { |cohort| [ cohort.id, cohort ] }.freeze,
          loaded: true, stale: false, loaded_at: loaded_at, checked_at: checked_at
        )
      end

      def rule(key)
        rules[key.to_sym]
      end

      def cohort(key)
        cohorts[key.to_s]
      end

      # Seconds since the last successful load, or nil if there never was one.
      def age(now = Time.now.utc)
        loaded_at && (now - loaded_at).round(3)
      end

      # Running rules for flags of `unit` that have direct members or an
      # attached cohort with members: the only ones a membership lookup can
      # change.
      def member_rules?(registry, unit)
        rules.each_value.any? do |rule|
          definition = registry[rule.key]
          next false unless rule.running? && definition && definition.unit == unit

          rule.members? || rule.cohort_attachments.any? { |key, _| cohort(key)&.member_count.to_i.positive? }
        end
      end
    end
  end
end
