require "time"


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
      :fallthrough_value, :stop_value, :conditions, :cohorts, :member_count, :lock_version, :full_since,
      :last_evaluated_at, :updated_at
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
          full_since: attributes[:full_since],
          last_evaluated_at: attributes[:last_evaluated_at],
          updated_at: attributes[:updated_at]
        )
      end

      Values::STATUSES.each do |name|
        define_method(:"#{name}?") { status == name }
      end

      # The accessors below check the stored shapes that jsonb allows but a
      # rule can't have, raising Resolver::Invalid so only that flag fails,
      # with PARSE_ERROR.

      # `[{ "name" => n, "value" => v }, ...]`
      def segments
        list = shaped(condition("segments") || [], Array, "conditions.segments")
        list.each { |segment| shaped(segment, Hash, "each of conditions.segments") }
      end

      def platforms
        shaped(condition("platforms") || [], Array, "conditions.platforms").map { |platform| platform.to_s.downcase }
      end

      # `{ "android" => ">=1.4.0 <2.0.0" }` (a StandardFlags::VersionRange;
      # RubyGems requirements stored by 0.2.x still read)
      def versions
        shaped(condition("versions") || {}, Hash, "conditions.versions")
          .to_h { |platform, requirement| [ platform.to_s.downcase, requirement ] }
      end

      # `{ "android" => ">=120 <200" }` (a StandardFlags::BuildRange)
      def builds
        shaped(condition("builds") || {}, Hash, "conditions.builds")
          .to_h { |platform, range| [ platform.to_s.downcase, range ] }
      end

      # `{ variant => weight }`
      def weights
        shaped(variant_weights, Hash, "variant_weights")
      end

      # `[[cohort_key, value], ...]` in declared order.
      def cohort_attachments
        shaped(cohorts, Array, "cohorts").map do |attachment|
          shaped(attachment, Hash, "each of cohorts")
          [ attachment["cohort"].to_s, attachment["value"] ]
        end
      end

      def members?
        member_count.positive?
      end

      # Whether serving this rule needs the flag's unit key.
      def needs_unit?
        members? || cohort_attachments.any? || segments.any? || !percentage_bps.nil? || weights.any?
      end

      # The rule's state as audit rows and notifications record it: every
      # setting, never a member.
      def audit_state
        {
          status: status, hash_version: hash_version, salt: salt, percentage_bps: percentage_bps,
          rollout_value: rollout_value, variant_weights: variant_weights, fallthrough_value: fallthrough_value,
          stop_value: stop_value, conditions: conditions, cohorts: cohorts, member_count: member_count,
          lock_version: lock_version, full_since: full_since&.utc&.iso8601
        }
      end

      private

      def condition(name)
        shaped(conditions, Hash, "conditions")[name]
      end

      def shaped(value, type, field)
        return value if value.is_a?(type)

        raise Resolver::Invalid, "has a malformed #{field} (expected #{type == Hash ? 'an object' : 'a list'})"
      end
    end

    # A named, reusable member list (a row of standard_flags_cohorts).
    Cohort = Data.define(:id, :key, :name, :description, :unit, :member_count, :archived_at) do
      def self.build(**attributes)
        new(
          id: attributes[:id],
          key: attributes.fetch(:key).to_s.freeze,
          name: attributes[:name]&.to_s&.freeze,
          description: attributes[:description]&.to_s&.freeze,
          unit: attributes.fetch(:unit).to_sym,
          member_count: attributes.fetch(:member_count, 0).to_i,
          archived_at: attributes[:archived_at]
        )
      end

      def archived?
        !archived_at.nil?
      end

      # The cohort as audit rows and notifications record it, without members.
      def audit_state
        { key: key, name: name, description: description, unit: unit.to_s, member_count: member_count,
          archived_at: archived_at&.utc&.iso8601 }
      end
    end

    # One live membership of a unit in a rule or a cohort. Stores never
    # return removed memberships; expired ones are dropped at read time.
    # `created_at` is set by the operator reads (Store#members,
    # Store#members_at) and may be nil on the read path.
    Membership = Data.define(:rule_id, :cohort_id, :unit, :unit_key, :value, :expires_at, :created_at) do
      def initialize(created_at: nil, **attributes)
        super
      end

      def live?(now)
        expires_at.nil? || expires_at > now
      end

      # Keeps unit keys (phone numbers, emails) out of logs and consoles.
      def inspect
        "#<StandardFlags::Runtime::Membership unit=#{unit} rule_id=#{rule_id.inspect} cohort_id=#{cohort_id.inspect}>"
      end
      alias_method :to_s, :inspect

      # pp and IRB's inspector would otherwise print every member. `to_h`
      # still includes the unit key.
      def pretty_print(q)
        q.text(inspect)
      end
    end

    # Everything a store returns from one load.
    Loaded = Data.define(:rules, :cohorts)

    # One page of an owner's memberships (Store#members): `total` counts
    # every membership not removed, expired ones included.
    MemberPage = Data.define(:memberships, :total)
  end
end
