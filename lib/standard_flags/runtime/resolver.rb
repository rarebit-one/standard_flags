module StandardFlags
  module Runtime
    # The runtime-rule layer of the evaluation chain, between the ENV pin and
    # the code default. Returns nil (so the code default serves) unless
    # runtime rules are on, the snapshot has loaded, and the flag's rule
    # decides.
    #
    # By status:
    #
    # * draft, paused — nil; a paused rule keeps its settings for Start.
    # * stopped       — `stop_value` for everyone (STATIC, "stopped").
    # * running       — the first of these that answers:
    #   1. direct memberships of this unit; one serving the off value (deny)
    #      wins over any other (TARGETING_MATCH, "deny" / "allow");
    #   2. attached cohorts the unit belongs to; one serving the off value
    #      wins, else the first in declared order ("cohort:<key>");
    #   3. segments, asked of `config.segment_resolver` ("segment:<name>");
    #   4. client conditions (platforms, version ranges); when unmet, skip
    #      straight to the fallthrough;
    #   5. the percentage: a unit whose rollout bucket is below
    #      `percentage_bps` gets the variant weights' pick when there are
    #      weights ("variants"), else `rollout_value` ("percentage"), both
    #      SPLIT; with weights and no percentage, every unit gets a variant;
    #   6. `fallthrough_value` (TARGETING_MATCH, "fallthrough"), else nil.
    #
    # A rule that needs the unit when the context has no key for it returns
    # the fallthrough (or the code default) with TARGETING_KEY_MISSING. A
    # stored value or shape the flag can't take fails only this flag (its
    # fail value, PARSE_ERROR), reported once. A kill switch served false
    # reads as KILL_SWITCH.
    #
    # When the unit's membership lookup fails, steps 1 and 2 are skipped and
    # the rest still decide, marked ERROR / GENERAL with the deciding step's
    # rule_id (none for the code default). The failure is memoised for the
    # unit of work and reported once, so it costs one failed query.
    class Resolver
      # A stored rule this flag can't serve. Internal; reported as RuleInvalid.
      class Invalid < StandardError; end

      def call(request)
        return unless Runtime.enabled?

        snapshot = Runtime.snapshot
        return unless snapshot.loaded

        rule = snapshot.rule(request.definition.key)
        return unless rule

        Runtime.tracker.track(rule.key) unless EvaluationTracker.untracked?
        Decision.new(request, rule, snapshot).call
      rescue Invalid => e
        invalid(request.definition, e)
      end

      private

      def invalid(definition, error)
        Reporting.once(:rule_invalid, definition.key, error.message) do
          Reporting.instrument(:rule_invalid, key: definition.key, error: error.message)
          Reporting.report(RuleInvalid.new("runtime rule for :#{definition.key} #{error.message}"), flag: definition.key.to_s)
        end
        Evaluation.build(definition, definition.fail_value, reason: Reason::ERROR, error_code: ErrorCode::PARSE_ERROR)
      end

      # One evaluation of one rule.
      class Decision
        attr_reader :definition, :context, :rule, :snapshot

        def initialize(request, rule, snapshot)
          @request = request
          @definition = request.definition
          @context = request.context
          @rule = rule
          @snapshot = snapshot
        end

        def call
          if rule.stopped? then serve(rule.stop_value, "stop_value", Reason::STATIC, "stopped")
          elsif rule.running? then running
          elsif !rule.draft? && !rule.paused? then raise Invalid, "has unknown status #{rule.status.inspect}"
          end
        end

        private

        def running
          key = unit_key
          return missing_unit if key.nil? && rule.needs_unit?

          members = key ? memberships(key) : []
          return without_members(key) if members.equal?(LOOKUP_FAILED)

          direct(members) || cohorts(members) || targeting(key)
        end

        def targeting(key)
          segments || (client_conditions_met? && split(key)) || fallthrough
        end

        def without_members(key)
          decided = targeting(key)
          value = decided ? decided.value : definition.default_for(@request.env_name)
          Evaluation.build(definition, value, reason: Reason::ERROR, error_code: ErrorCode::GENERAL, rule_id: decided&.rule_id)
        end

        def unit_key
          Runtime.unit_key(@request.registry, definition, context)
        end

        # Skipped entirely when no direct member or attached cohort member
        # could match.
        def memberships(key)
          return [] unless rule.members? || attached_cohorts.any? { |cohort, _| cohort.member_count.positive? }

          found = Runtime.memberships(definition.unit, key)
          return found if found.equal?(LOOKUP_FAILED)

          now = Time.now
          found.select { |membership| membership.live?(now) }
        end

        def direct(members)
          values = members.select { |m| m.rule_id == rule.id }.map { |m| cast(m.value, "a membership value") }
          return if values.empty?

          denied = values.include?(definition.off_value)
          build(denied ? definition.off_value : values.first, Reason::TARGETING_MATCH, denied ? "deny" : "allow")
        end

        def cohorts(members)
          ids = members.filter_map(&:cohort_id)
          matched = attached_cohorts.filter_map do |cohort, value|
            [ cohort.key, cast(value, "cohort #{cohort.key}'s value") ] if ids.include?(cohort.id)
          end
          return if matched.empty?

          key, value = matched.find { |_, served| served == definition.off_value } || matched.first
          build(value, Reason::TARGETING_MATCH, "cohort:#{key}")
        end

        # [[Cohort, stored value], ...] for live cohorts of this flag's unit.
        def attached_cohorts
          @attached_cohorts ||= rule.cohort_attachments.filter_map do |key, value|
            cohort = snapshot.cohort(key)
            [ cohort, value ] if cohort && !cohort.archived? && cohort.unit == definition.unit
          end
        end

        def segments
          resolver = StandardFlags.config.segment_resolver
          return unless resolver

          rule.segments.each do |segment|
            name = segment["name"].to_s
            return serve(segment["value"], "segment #{name}'s value", Reason::TARGETING_MATCH, "segment:#{name}") if resolver.call(name, context)
          end
          nil
        end

        def client_conditions_met?
          platforms = rule.platforms
          versions = rule.versions
          return true if platforms.empty? && versions.empty?

          platform = context.client[:platform]&.to_s&.downcase
          return false if platforms.any? && !platforms.include?(platform)

          requirement = platform && versions[platform]
          requirement.nil? || version_satisfies?(requirement, context.client[:version])
        end

        def version_satisfies?(requirement, version)
          parsed = begin
            Gem::Requirement.new(*requirement.to_s.split(",").map(&:strip))
          rescue Gem::Requirement::BadRequirementError
            raise Invalid, "has an invalid version range #{requirement.inspect}"
          end
          return false if version.to_s.strip.empty?

          parsed.satisfied_by?(Gem::Version.new(version.to_s.strip))
        rescue ArgumentError
          false # an unparseable client version meets no range
        end

        def split(key)
          bps = rule.percentage_bps
          return if bps.nil? && rule.weights.empty?
          raise Invalid, "has percentage_bps #{bps.inspect} outside 0..10000" if bps && !(0..Bucket::BUCKETS).cover?(bps)
          return if bps && bucket("rollout", key) >= bps
          return variants(key) if rule.weights.any?

          serve(rule.rollout_value || default_rollout_value, "rollout_value", Reason::SPLIT, "percentage")
        end

        # Booleans roll out to "on"; other kinds must name the value.
        def default_rollout_value
          definition.boolean? ? "on" : nil
        end

        def variants(key)
          weights = rule.weights.to_h { |variant, weight| [ cast(variant, "variant weights"), weight ] }
          unless weights.values.all?(Integer) && weights.values.all? { |w| w >= 0 } && weights.values.sum == Bucket::BUCKETS
            raise Invalid, "has variant weights that don't sum to #{Bucket::BUCKETS}"
          end

          position = bucket("variant", key)
          upper = 0
          value = definition.allowed_values.find { |candidate| position < (upper += weights.fetch(candidate, 0)) }
          build(value, Reason::SPLIT, "variants")
        end

        def bucket(decision, key)
          case rule.hash_version
          when 1 then Bucket.v1(rule.salt, key)
          when 2 then Bucket.v2(decision, rule.salt, key)
          else raise Invalid, "has unknown hash_version #{rule.hash_version.inspect}"
          end
        end

        def fallthrough
          return if rule.fallthrough_value.nil?

          serve(rule.fallthrough_value, "fallthrough_value", Reason::TARGETING_MATCH, "fallthrough")
        end

        def missing_unit
          Reporting.instrument(:targeting_key_missing, key: definition.key, unit: definition.unit)
          if rule.fallthrough_value
            value = cast(rule.fallthrough_value, "fallthrough_value")
            rule_id = "fallthrough"
          else
            value = definition.default_for(@request.env_name)
          end
          Evaluation.build(definition, value, reason: Reason::ERROR, error_code: ErrorCode::TARGETING_KEY_MISSING,
                                              rule_id: rule_id)
        end

        def serve(stored, field, reason, rule_id)
          build(cast(stored, field), reason, rule_id)
        end

        def build(value, reason, rule_id)
          reason = Reason::KILL_SWITCH if definition.kill_switch? && value == false
          Evaluation.build(definition, value, reason: reason, rule_id: rule_id)
        end

        def cast(stored, field)
          value = definition.value_from_wire(stored)
          raise Invalid, "has #{stored.inspect} in #{field}, not one of #{definition.allowed_values.map { |v| Runtime.wire(v) }.join('/')}" if value.equal?(Parser::INVALID)

          value
        end
      end
    end
  end
end
