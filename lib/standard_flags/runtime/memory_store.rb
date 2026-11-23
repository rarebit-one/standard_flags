module StandardFlags
  module Runtime
    # An in-process store, for specs and for apps without a database. Every
    # write bumps the revision, so the cache picks it up at its next check.
    # Thread-safe. `reads` counts calls per method, so specs can assert what
    # evaluation cost without a database.
    #
    #   store = StandardFlags::Runtime::MemoryStore.new
    #   store.put_rule(:new_checkout, status: :running, percentage_bps: 500)
    #   store.put_cohort(:staff, unit: :account)
    #   store.add_member(cohort: :staff, unit: :account, unit_key: "42", value: true)
    #   StandardFlags.configure { |c| c.runtime_rules = true; c.runtime_store = store }
    #
    # Values may be given as Ruby values (true, false, :sensor) or as their
    # stored strings ("on", "off", "sensor").
    class MemoryStore < Store
      RULE_ATTRIBUTES = %i[
        status hash_version salt percentage_bps rollout_value variant_weights
        fallthrough_value stop_value conditions cohorts
      ].freeze

      attr_reader :reads

      def initialize
        @mutex = Mutex.new
        @revision = 0
        @next_id = 0
        @rules = {}
        @cohorts = {}
        @memberships = []
        @reads = Hash.new(0)
      end

      def revision
        @mutex.synchronize do
          @reads[:revision] += 1
          @revision
        end
      end

      def load
        @mutex.synchronize do
          @reads[:load] += 1
          Loaded.new(rules: @rules.values, cohorts: @cohorts.values)
        end
      end

      def memberships(unit, unit_keys)
        unit = unit.to_sym
        keys = unit_keys.map(&:to_s)
        @mutex.synchronize do
          @reads[:memberships] += 1
          @memberships.select { |m| m.unit == unit && keys.include?(m.unit_key) }
        end
      end

      # The stored rule for `key`, or nil. Not counted in `reads`.
      def rule(key)
        @mutex.synchronize { @rules[key.to_sym] }
      end

      # Creates or replaces the rule for `key`. Unset attributes keep their
      # current value; the salt defaults to the key.
      def put_rule(key, **attributes)
        unknown = attributes.keys - RULE_ATTRIBUTES
        raise ArgumentError, "unknown rule attribute(s): #{unknown.join(', ')}" unless unknown.empty?

        key = key.to_sym
        write do
          current = @rules[key]&.to_h || { id: next_id, key: key, salt: key.to_s }
          rule = Rule.build(**current.merge(normalize_rule(attributes), member_count: count_members(rule_id: current[:id])))
          raise ArgumentError, "status must be one of #{Values::STATUSES.join('/')}" unless Values::STATUSES.include?(rule.status)

          @rules[key] = rule
        end
      end

      def put_cohort(key, unit:, name: nil, archived_at: nil)
        key = key.to_s
        write do
          id = @cohorts[key]&.id || next_id
          @cohorts[key] = Cohort.build(id: id, key: key, name: name, unit: unit, archived_at: archived_at,
                                       member_count: count_members(cohort_id: id))
        end
      end

      # Adds (or replaces) one membership on a rule or a cohort.
      def add_member(unit:, unit_key:, value:, rule: nil, cohort: nil, expires_at: nil)
        write do
          rule_id, cohort_id = owner_ids(rule, cohort)
          unit = unit.to_sym
          unit_key = unit_key.to_s
          @memberships.reject! { |m| m.rule_id == rule_id && m.cohort_id == cohort_id && m.unit == unit && m.unit_key == unit_key }
          @memberships << Membership.new(rule_id: rule_id, cohort_id: cohort_id, unit: unit, unit_key: unit_key,
                                         value: Runtime.wire(value), expires_at: expires_at)
          recount(rule_id, cohort_id)
        end
      end

      def remove_member(unit:, unit_key:, rule: nil, cohort: nil)
        write do
          rule_id, cohort_id = owner_ids(rule, cohort)
          @memberships.reject! do |m|
            m.rule_id == rule_id && m.cohort_id == cohort_id && m.unit == unit.to_sym && m.unit_key == unit_key.to_s
          end
          recount(rule_id, cohort_id)
        end
      end

      private

      def write
        @mutex.synchronize do
          result = yield
          @revision += 1
          result
        end
      end

      def next_id
        @next_id += 1
      end

      def normalize_rule(attributes)
        attributes.to_h do |name, value|
          value =
            case name
            when :status then value.to_s
            when :rollout_value, :fallthrough_value, :stop_value then Runtime.wire(value)
            when :variant_weights then value.to_h { |variant, weight| [ Runtime.wire(variant), weight ] }
            when :cohorts then normalize_attachments(value)
            else value
            end
          [ name, value ]
        end
      end

      # `{ staff: true }` or `[{ cohort: :staff, value: true }]`, in order.
      def normalize_attachments(value)
        pairs = value.is_a?(Hash) ? value.to_a : Array(value).map { |a| a.to_h.transform_keys(&:to_s).values_at("cohort", "value") }
        pairs.map { |cohort, served| { "cohort" => cohort.to_s, "value" => Runtime.wire(served) } }
      end

      def owner_ids(rule, cohort)
        raise ArgumentError, "pass exactly one of rule: or cohort:" unless rule.nil? ^ cohort.nil?

        if rule
          [ @rules.fetch(rule.to_sym) { raise ArgumentError, "no rule for :#{rule}; put_rule first" }.id, nil ]
        else
          [ nil, @cohorts.fetch(cohort.to_s) { raise ArgumentError, "no cohort #{cohort.inspect}; put_cohort first" }.id ]
        end
      end

      def count_members(rule_id: nil, cohort_id: nil)
        return 0 if rule_id.nil? && cohort_id.nil?

        @memberships.count { |m| rule_id ? m.rule_id == rule_id : m.cohort_id == cohort_id }
      end

      def recount(rule_id, cohort_id)
        if rule_id
          key, rule = @rules.find { |_, r| r.id == rule_id }
          @rules[key] = rule.with(member_count: count_members(rule_id: rule_id))
        else
          key, cohort = @cohorts.find { |_, c| c.id == cohort_id }
          @cohorts[key] = cohort.with(member_count: count_members(cohort_id: cohort_id))
        end
      end
    end
  end
end
