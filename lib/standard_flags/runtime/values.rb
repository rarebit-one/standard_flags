module StandardFlags
  module Runtime
    # Immutable, store-independent copies of runtime rows. Stores build them;
    # the resolver reads them. Values are the stored strings ("on", "off", a
    # mode value or a variant); the resolver casts them through the flag's
    # definition.
    module Values
      STATUSES = %w[draft running paused stopped].freeze

      module_function

      def deep_freeze(value)
        case value
        when Hash then value.to_h { |k, v| [ k.to_s.freeze, deep_freeze(v) ] }.freeze
        when Array then value.map { |v| deep_freeze(v) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end

    # One flag's runtime rule (a row of standard_flags_rules).
    Rule = Data.define(
      :id, :key, :status, :hash_version, :salt, :percentage_bps, :rollout_value, :variant_weights,
      :fallthrough_value, :stop_value, :conditions, :cohorts, :member_count, :lock_version, :updated_at
    ) do
      def self.build(**attributes)
        new(
          id: attributes[:id],
          key: attributes.fetch(:key).to_sym,
          status: attributes.fetch(:status, "draft").to_s.freeze,
          hash_version: attributes.fetch(:hash_version, 2),
          salt: attributes.fetch(:salt).to_s.freeze,
          percentage_bps: attributes[:percentage_bps],
          rollout_value: attributes[:rollout_value]&.to_s&.freeze,
          variant_weights: Values.deep_freeze(attributes[:variant_weights] || {}),
          fallthrough_value: attributes[:fallthrough_value]&.to_s&.freeze,
          stop_value: attributes[:stop_value]&.to_s&.freeze,
          conditions: Values.deep_freeze(attributes[:conditions] || {}),
          cohorts: Values.deep_freeze(attributes[:cohorts] || []),
          member_count: attributes.fetch(:member_count, 0).to_i,
          lock_version: attributes.fetch(:lock_version, 0).to_i,
          updated_at: attributes[:updated_at]
        )
      end

      Values::STATUSES.each do |name|
        define_method(:"#{name}?") { status == name }
      end

      def segments
        Array(conditions["segments"])
      end

      def platforms
        Array(conditions["platforms"]).map { |platform| platform.to_s.downcase }
      end

      def versions
        (conditions["versions"] || {}).to_h { |platform, requirement| [ platform.to_s.downcase, requirement ] }
      end

      # `[[cohort_key, value], ...]` in declared order.
      def cohort_attachments
        cohorts.map { |attachment| [ attachment["cohort"].to_s, attachment["value"] ] }
      end

      def members?
        member_count.positive?
      end

      # Whether serving this rule needs the flag's unit key.
      def needs_unit?
        members? || cohorts.any? || segments.any? || !percentage_bps.nil? || variant_weights.any?
      end
    end

    # A named, reusable member list (a row of standard_flags_cohorts).
    Cohort = Data.define(:id, :key, :name, :unit, :member_count, :archived_at) do
      def self.build(**attributes)
        new(
          id: attributes[:id],
          key: attributes.fetch(:key).to_s.freeze,
          name: attributes[:name]&.to_s&.freeze,
          unit: attributes.fetch(:unit).to_sym,
          member_count: attributes.fetch(:member_count, 0).to_i,
          archived_at: attributes[:archived_at]
        )
      end

      def archived?
        !archived_at.nil?
      end
    end

    # One live membership of a unit in a rule or a cohort. Stores never
    # return removed memberships; expired ones are dropped at read time.
    Membership = Data.define(:rule_id, :cohort_id, :unit, :unit_key, :value, :expires_at) do
      def live?(now)
        expires_at.nil? || expires_at > now
      end

      # Keeps unit keys (phone numbers, emails) out of logs and consoles.
      def inspect
        "#<StandardFlags::Runtime::Membership unit=#{unit} rule_id=#{rule_id.inspect} cohort_id=#{cohort_id.inspect}>"
      end
      alias_method :to_s, :inspect
    end

    # Everything a store returns from one load.
    Loaded = Data.define(:rules, :cohorts)
  end
end
