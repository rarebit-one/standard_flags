module StandardFlags
  module Operations
    # Draft or paused → running, after checking everything the rule would
    # serve (Base checks every running rule after the change).
    class Start < Base
      arguments

      private

      def event = Events::FLAG_EVENTS[:started]

      def extra_cohort_keys
        validate.attachments(definition, @rule)
      end

      def perform
        unless @rule.draft? || @rule.paused?
          raise Failure.new(:invalid, ":#{@key} is #{@rule.status}; only a draft or paused rule can start")
        end

        save!(status: "running")
        nil
      end
    end

    # Running → paused. A paused rule keeps its settings, so Start resumes
    # it, and serves the code default meanwhile.
    class Pause < Base
      arguments

      private

      def event = Events::FLAG_EVENTS[:paused]

      def perform
        raise Failure.new(:invalid, ":#{@key} is #{@rule.status}; only a running rule can pause") unless @rule.running?

        save!(status: "paused")
        nil
      end
    end

    # → stopped, serving `serve:` to everyone (the winner, or the flag's
    # `final:`) until the code drops the flag.
    class Stop < Base
      arguments required: %i[serve]

      private

      def event = Events::FLAG_EVENTS[:stopped]

      def perform
        save!(status: "stopped", stop_value: validate.value!(definition, arg(:serve), "serve"))
        nil
      end
    end

    # Sets the percentage of units (in basis points, 0–10,000) that get the
    # rollout value, and `value:`, the rollout value itself (on/off flags
    # roll out to on). Reaching 10,000 records full_since.
    class Ramp < Base
      scope "flags:ramp"
      arguments required: %i[bps], optional: %i[value]

      private

      def event = Events::FLAG_EVENTS[:ramped]

      def perform
        validate.unit!(definition, registry, "a percentage")
        bps = validate.bps!(arg(:bps))
        rollout = args.key?(:value) ? validate.value!(definition, arg(:value), "value") : @rule.rollout_value
        if !definition.boolean? && rollout.nil? && @rule.variant_weights.empty?
          raise Failure.new(:invalid, ":#{@key} is a #{definition.kind}; pass value: (what the percentage serves)")
        end

        full_since = bps == Bucket::BUCKETS ? (@rule.full_since || Time.now.utc) : nil
        save!(percentage_bps: bps, rollout_value: rollout, full_since: full_since)
        nil
      end
    end

    # Sets variant weights over the flag's variants or mode values, summing
    # to 10,000. An empty Hash clears them.
    class SetVariants < Base
      scope "flags:ramp"
      arguments required: %i[weights]

      private

      def event = Events::FLAG_EVENTS[:variants_set]

      def perform
        validate.unit!(definition, registry, "variant weights")
        save!(variant_weights: validate.weights!(definition, arg(:weights)))
        nil
      end
    end

    # Sets the fallthrough value, served to every unit no other part of a
    # running rule matched. This is how a mode moves off → sensor → on at
    # runtime, and how a kill switch is thrown from the database.
    # `value: nil` clears it, so the code default serves.
    #
    # Setting a value on a draft rule (including the one created on first
    # use) also starts it, in the same write: "set the kill switch off"
    # serves at once rather than waiting for a Start. The running rule is
    # checked as Start checks it, and anything staged on the draft (a ramp,
    # variants, conditions, members, cohorts) serves from then on too. The
    # Result's value and the `value_set` event carry `started: true`; no
    # separate `started` event is published, and the one audit row's before
    # and after show both the status and the value. Clearing (`nil`) never
    # starts a rule.
    #
    # A paused rule stays paused (someone stood it down on purpose): the
    # value is stored, and the Result warns that it isn't served until
    # Start. A running or stopped rule keeps its status.
    class SetValue < Base
      PAUSED = "rule is paused; the value is stored but not served until Start".freeze

      arguments required: %i[value]

      private

      def event = Events::FLAG_EVENTS[:value_set]

      # The cohorts a draft attaches, which the check of the started rule
      # reads.
      def extra_cohort_keys
        starts? ? validate.attachments(definition, @rule) : []
      end

      def perform
        value = arg(:value).nil? ? nil : validate.value!(definition, arg(:value), "value")
        started = starts?
        warn_caller(PAUSED) if @rule.paused? && !value.nil?
        save!(fallthrough_value: value, **(started ? { status: "running" } : {}))
        { started: started }
      end

      def starts?
        @rule.draft? && !arg(:value).nil?
      end
    end

    # Replaces the rule's conditions: `platforms:` (client platforms that
    # may get the percentage and variants), `versions:` (a version range per
    # platform) and `segments:` (`{ name => value }`, asked of
    # `config.segment_resolver`, in order). Omitted ones are cleared.
    class SetConditions < Base
      arguments optional: %i[platforms versions segments]

      private

      def event = Events::FLAG_EVENTS[:conditions_set]

      def perform
        conditions = { "platforms" => platforms, "versions" => versions, "segments" => segments }.reject { |_, v| v.empty? }
        validate.conditions_size!(conditions, config)
        save!(conditions: conditions)
        nil
      end

      def platforms
        list = Array(arg(:platforms))
        unless list.all? { |p| (p.is_a?(String) || p.is_a?(Symbol)) && !p.to_s.strip.empty? }
          raise Failure.new(:invalid, "platforms must be a list of names")
        end

        list.map { |platform| platform.to_s.downcase }.uniq
      end

      def versions
        ranges = arg(:versions) || {}
        raise Failure.new(:invalid, "versions must be a Hash of platform => range") unless ranges.is_a?(Hash)

        ranges.to_h { |platform, range| [ platform.to_s.downcase, validate.version_range!(range) ] }
      end

      def segments
        given = arg(:segments) || {}
        pairs = given.is_a?(Hash) ? given.to_a : Array(given).map { |s| s.to_h.transform_keys(&:to_s).values_at("name", "value") }
        validate.unit!(definition, registry, "segments") unless pairs.empty?
        pairs.map do |name, value|
          raise Failure.new(:invalid, "segment names must not be blank") if name.to_s.strip.empty?

          { "name" => name.to_s, "value" => validate.value!(definition, value, "segment #{name}'s value") }
        end
      end
    end

    # Shared by AttachCohort and DetachCohort: the policy must allow both
    # the flag and the cohort.
    module CohortAttachment
      private

      def cohort_key
        arg(:cohort).to_s.delete_prefix("cohort:")
      end

      def authorization_keys
        [ *super, "cohort:#{cohort_key}" ]
      end
    end

    # Attaches a cohort to a flag's rule, serving `value:` to its members.
    # Attaching it again changes the value and keeps its place in the order.
    class AttachCohort < Base
      include CohortAttachment

      arguments required: %i[cohort value]

      private

      def event = Events::COHORT_EVENTS[:attached]

      def extra_cohort_keys
        [ cohort_key ]
      end

      def perform
        key = cohort_key
        validate.unit!(definition, registry, "cohorts")
        validate.cohort!(definition, key, @cohorts[key])
        value = validate.value!(definition, arg(:value), "value")
        attachments = @rule.cohorts.map(&:dup)
        if (existing = attachments.find { |a| a["cohort"] == key })
          existing["value"] = value
        else
          attachments << { "cohort" => key, "value" => value }
        end
        if attachments.size > config.max_cohorts_per_rule
          raise Failure.new(:limit_exceeded, ":#{@key} would have #{attachments.size} cohorts; the limit is #{config.max_cohorts_per_rule}")
        end

        save!(cohorts: attachments)
        { cohort: key }
      end
    end

    # Detaches a cohort from a flag's rule.
    class DetachCohort < Base
      include CohortAttachment

      arguments required: %i[cohort]

      private

      def event = Events::COHORT_EVENTS[:detached]

      def perform
        key = cohort_key
        attachments = @rule.cohorts.reject { |a| a["cohort"] == key }
        raise Failure.new(:invalid, "cohort #{key.inspect} is not attached to :#{@key}") if attachments.size == @rule.cohorts.size

        save!(cohorts: attachments)
        { cohort: key }
      end
    end
  end
end
