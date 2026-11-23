require "securerandom"

module StandardFlags
  module Operations
    # The steps every operation takes, in order:
    #
    # 1. Resolve the actor: `actor:`, else `config.actor_resolver`. With
    #    neither, it fails (:actor_missing); pass `StandardFlags::Actor.system`
    #    for work no person does.
    # 2. Authorise through `config.authorize.call(actor, scope, key)`
    #    (:unauthorized).
    # 3. Refuse unknown (:unknown_flag) and tombstoned (:tombstoned_flag)
    #    keys, and flags an ENV pin decides (:pinned_by_env; the error names
    #    the variable, never its value).
    # 4. In one store write: create the rule on first use (salt and hash
    #    version from the flag's `bucketing:`, else a random salt and v2) and
    #    lock it, then the cohorts it needs (by id); check
    #    `expected_revision` against its lock_version (:stale_revision);
    #    validate (:invalid, :limit_exceeded); save, keeping member_count and
    #    full_since in step; check the whole rule again if it is running, so
    #    no edit leaves one the read path can't serve; increment the state
    #    revision; write the audit row (Audit.record).
    # 5. Once the write has committed: expire the process cache, clear the
    #    unit of work's memo, and publish (Audit.announce). Inside a host
    #    transaction that is when the host commits.
    #
    # Results carry `value: { key: or cohort:, rule: or state:, revision:,
    # store_revision: }` plus what the operation changed. `revision` is the
    # number `expected_revision` is checked against: a rule's lock_version,
    # or for cohort operations the store's revision. `store_revision` is
    # always the store's. `warnings` lists anything about a committed change
    # the caller should know (SetValue on a paused rule, say). Success
    # means the write committed (or, inside a host transaction, will commit
    # with it). Every failure is a Result, never an exception; store and
    # unexpected errors are reported through `config.error_reporter` /
    # Rails.error (:store_error, :error).
    class Base
      class << self
        def call(target, actor: nil, reason: nil, expected_revision: nil, registry: StandardFlags.registry, **args)
          new(target, actor: actor, reason: reason, expected_revision: expected_revision, registry: registry, args: args).call
        end

        # "flags:write" unless the operation says otherwise.
        def scope(name = nil)
          @scope = name if name
          @scope || "flags:write"
        end

        # Argument names: `required` must be given, `optional` may be.
        def arguments(required: [], optional: [])
          @required = required.freeze
          @optional = optional.freeze
        end

        def required_arguments
          @required || []
        end

        def optional_arguments
          @optional || []
        end

        # The operation's name in errors and reports: "ramp", "add_members".
        def operation_name
          name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
        end
      end

      attr_reader :actor, :reason, :registry, :args

      def initialize(target, actor:, reason:, expected_revision:, registry:, args:)
        @target = target
        @given_actor = actor
        @reason = reason
        @expected_revision = expected_revision
        @registry = registry
        @args = args
      end

      def call
        @actor = resolve_actor
        check_reason!
        check_arguments!
        parse_target!
        authorize!
        check_target!
        check_runtime!
        @announcements = []
        @warnings = []
        value = Runtime.store.write do |tx|
          @tx = tx
          run.tap { tx.after_commit { committed } }
        end
        Result.new(success: true, value: value, warnings: @warnings)
      rescue Failure => e
        Result.failure(e.code, e.message)
      rescue Runtime::StoreError => e
        Reporting.report(e, operation: self.class.operation_name, **report_context)
        Result.failure(:store_error, e.message)
      rescue StandardError => e
        raise if e.class.name == "StandardAudit::Operation::DeclarationError"

        report_unexpected(e)
        Result.failure(:error, "#{self.class.operation_name} failed: #{e.class}")
      end

      private

      attr_reader :tx, :definition

      # -- steps -------------------------------------------------------------

      def resolve_actor
        actor = @given_actor || StandardFlags.config.actor_resolver&.call
        return actor unless actor.nil?

        raise Failure.new(:actor_missing, "no actor: pass actor:, configure config.actor_resolver, " \
                                          "or use StandardFlags::Actor.system(...)")
      end

      def check_reason!
        return if @reason.is_a?(String) && !@reason.strip.empty?

        raise Failure.new(:invalid, "a reason is required")
      end

      def check_arguments!
        klass = self.class
        unknown = args.keys - klass.required_arguments - klass.optional_arguments
        missing = klass.required_arguments - args.keys
        raise Failure.new(:invalid, "unknown argument(s): #{unknown.join(', ')}") unless unknown.empty?
        raise Failure.new(:invalid, "missing argument(s): #{missing.join(', ')}") unless missing.empty?
        return if @expected_revision.nil? || @expected_revision.is_a?(Integer)

        raise Failure.new(:invalid, "expected_revision must be an Integer")
      end

      # Sets @key (a flag key Symbol) or @cohort_key (a String).
      def parse_target!
        text = @target.to_s
        if text.start_with?("cohort:")
          @cohort_key = text.delete_prefix("cohort:")
        else
          @key = text.to_sym
        end
        accepts = self.class.respond_to?(:targets) ? self.class.targets : %i[flag]
        raise Failure.new(:invalid, "#{self.class.operation_name} takes a flag key, not a cohort") if @cohort_key && !accepts.include?(:cohort)
        raise Failure.new(:invalid, "#{self.class.operation_name} takes a cohort, not a flag key") if @key && !accepts.include?(:flag)
      end

      def authorization_key
        @key || "cohort:#{@cohort_key}"
      end

      # Every key the policy must allow; operations that also touch a cohort
      # add it.
      def authorization_keys
        [ authorization_key ]
      end

      def authorize!
        authorization_keys.each do |key|
          allowed = begin
            StandardFlags.config.authorize.call(actor, self.class.scope, key)
          rescue StandardError => e
            Reporting.report(e, operation: self.class.operation_name, **report_context)
            false
          end
          raise Failure.new(:unauthorized, "#{Actor.label(actor)} may not #{self.class.scope} #{key.inspect}") unless allowed
        end
      end

      def check_target!
        return check_cohort_key! if @cohort_key

        if registry.tombstoned?(@key)
          raise Failure.new(:tombstoned_flag, "flag :#{@key} was removed on #{registry.tombstones[@key].removed.iso8601}")
        end
        @definition = registry[@key]
        raise Failure.new(:unknown_flag, "unknown flag :#{@key}") unless @definition

        pin = EnvPin.scan(@definition, StandardFlags.config.env_source).pin
        return unless pin

        raise Failure.new(:pinned_by_env, "flag :#{@key} is pinned by #{pin.var}; unset it to change the flag here")
      end

      def check_cohort_key!
        return if @cohort_key.match?(Definition::KEY_FORMAT)

        raise Failure.new(:invalid, "cohort key #{@cohort_key.inspect} must match #{Definition::KEY_FORMAT.inspect}")
      end

      def check_runtime!
        return if Runtime.enabled?

        raise Failure.new(:runtime_rules_off, "runtime rules are off; set config.runtime_rules = true first")
      end

      # Rule operations: lock (creating on first use) the rule, then its
      # cohorts, check the revision, perform, re-check a running rule, bump,
      # record.
      def run
        @rule = tx.lock_rule(@key) || tx.create_rule(@key, **bucketing)
        check_revision!(@rule.lock_version)
        @cohorts = tx.lock_cohorts(cohort_keys)
        before = @rule.audit_state
        extra = perform || {}
        validate.rule!(definition, @rule, registry, @cohorts) if @rule.running?
        store_revision = Runtime.bump_revision!(tx)
        revisions = { revision: @rule.lock_version, store_revision: store_revision }
        publish(event, { key: @key.to_s, before: before, after: @rule.audit_state, **revisions, **extra })
        { key: @key, rule: @rule.audit_state, **revisions, **extra }
      end

      # The cohorts to lock (in id order, after the rule): those a running
      # rule attaches, which its re-check reads, plus `extra_cohort_keys`.
      def cohort_keys
        attached = @rule.running? ? validate.attachments(definition, @rule) : []
        (attached + extra_cohort_keys).uniq
      end

      def extra_cohort_keys
        []
      end

      def bucketing
        declared = definition.bucketing
        { salt: declared&.salt || SecureRandom.hex(16), hash_version: declared&.version || 2 }
      end

      def check_revision!(current)
        return if @expected_revision.nil? || @expected_revision == current

        raise Failure.new(:stale_revision, "#{authorization_key.inspect} is at revision #{current}, " \
                                           "not #{@expected_revision}; reload and try again")
      end

      # Records the audit row now, inside the write, and queues the
      # announcement for after the commit.
      def publish(event, payload)
        payload = { actor: actor.is_a?(Actor) ? nil : actor, actor_label: Actor.label(actor), reason: @reason }.merge(payload)
        published = Audit.record(tx, event, payload)
        @announcements << -> { Audit.announce(event, payload, published: published) }
      end

      # Runs once the write has committed. Never raises: the change is in.
      def committed
        Runtime.expire!
        Memo.clear!
        @announcements.each(&:call)
      rescue StandardError => e
        warn "[standard_flags] after-commit step of #{self.class.operation_name} failed: #{e.class}"
      end

      def save!(attributes)
        @rule = tx.save_rule(@rule, attributes)
      end

      # Adds a warning to the Result; the change still commits.
      def warn_caller(message)
        @warnings << message
      end

      # -- helpers -----------------------------------------------------------

      def arg(name)
        args[name]
      end

      def validate
        Validation
      end

      def config
        StandardFlags.config
      end

      def report_context
        if @key then { flag: @key.to_s }
        elsif @cohort_key then { cohort: @cohort_key }
        else {}
        end
      end

      # Unexpected errors are reported as they are, except from operations
      # that handle unit keys, whose messages could quote one.
      def report_unexpected(error)
        error = Error.new("#{self.class.operation_name} failed: #{error.class}") if sensitive?
        Reporting.report(error, operation: self.class.operation_name, **report_context)
      end

      def sensitive?
        false
      end
    end
  end
end
