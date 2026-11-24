module StandardFlags
  module MCP
    # Gates an app's own MCP tools on flags. Include it in any tool class
    # (one with `name`, `description`, `input_schema` and
    # `call(arguments, actor:)`, the shape StandardFlags::MCP::Tool has) and
    # declare the flags it needs:
    #
    #   class SummariseThread
    #     include StandardFlags::MCP::Gated
    #
    #     requires_flag :ai_assistant                                   # evaluated for the actor
    #     requires_flag :thread_tools, for: ->(actor) { actor.account }, client: -> { Current.client }
    #
    #     def name = "summarise_thread"
    #     def call(arguments, actor:) = ...
    #   end
    #
    # While any of them is off, `call` returns the tool error
    # `{ "error" => { "code" => "feature_disabled", "message" => "threadTools is disabled" } }`
    # without running the tool, and StandardFlags::MCP.visible leaves the
    # tool out of `tools/list`. The message names the flag's wire name for
    # the `:mcp` audience (else its first wire name, else the key). The gate
    # holds in every subclass, including one that defines its own `call`, and
    # a StandardFlags::FeatureDisabled raised inside the tool comes back as
    # the same error.
    #
    # `for:` says who the flag is evaluated for: anything `for:` takes
    # elsewhere, or a callable (a lambda runs in the tool instance) that may
    # take the actor. By default it is the actor. `client:` is a
    # StandardFlags::Client, a Hash, or a callable returning one. A nil
    # `actor:` resolves through `config.actor_resolver`, as the gem's own
    # tools do.
    #
    # Listing and calling evaluate identically: StandardFlags::MCP.visible
    # and StandardFlags::MCP.call take the same `actor:`, `context:` and
    # `client:`, so a tool listed for a request is callable by it and one
    # hidden from it is refused. The gem's own operator tools are not gated.
    module Gated
      Requirement = Data.define(:key, :target, :client)
      # The `context:` and `client:` of the StandardFlags::MCP.call in
      # progress.
      Scope = Data.define(:context, :client)
      SCOPE_KEY = :standard_flags_mcp_scope
      # The tools whose gate already passed in the calls in progress, so a
      # subclass's `call` reaching its parent's through `super` doesn't
      # evaluate the gate again.
      PASSED_KEY = :standard_flags_mcp_passed
      AUDIENCE = :mcp

      def self.included(base)
        base.extend(ClassMethods)
        base.prepend(Guard)
      end

      # The scope a gate reads, or nil outside StandardFlags::MCP.call.
      #
      # @api private
      def self.scope
        ActiveSupport::IsolatedExecutionState[SCOPE_KEY]
      end

      # @api private
      def self.within(context:, client:)
        previous = scope
        ActiveSupport::IsolatedExecutionState[SCOPE_KEY] = Scope.new(context: context, client: client)
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[SCOPE_KEY] = previous
      end

      # @api private
      def self.actor(actor)
        actor.nil? ? StandardFlags.config.actor_resolver&.call : actor
      end

      module ClassMethods
        def requires_flag(key, for: nil, client: nil)
          unless client.nil? || client.is_a?(Hash) || client.respond_to?(:call)
            raise ArgumentError, "client: must be a StandardFlags::Client, a Hash or a callable"
          end

          target = binding.local_variable_get(:for)
          (@standard_flags_requirements ||= []) << Requirement.new(key.to_sym, target, client)
          self
        end

        # Every requirement, a superclass's first.
        def standard_flags_requirements
          inherited = superclass.respond_to?(:standard_flags_requirements) ? superclass.standard_flags_requirements : []
          inherited + (@standard_flags_requirements || [])
        end

        private

        # A subclass's own `call` would otherwise sit in front of the guard.
        def inherited(subclass)
          super
          subclass.prepend(Guard)
        end
      end

      # Runs before the tool's own `call`, once per call: every subclass
      # has one (so a subclass's own `call` can't skip it), and the ones a
      # call reaches through `super` see that the gate already passed.
      module Guard
        def call(*arguments, **options, &block)
          passed = ActiveSupport::IsolatedExecutionState[PASSED_KEY] || []
          return super if passed.any? { |tool| tool.equal?(self) }

          scope = Gated.scope
          disabled = standard_flags_disabled(actor: options[:actor], context: scope&.context, client: scope&.client)
          return MCP.feature_disabled(disabled) if disabled

          begin
            ActiveSupport::IsolatedExecutionState[PASSED_KEY] = passed + [ self ]
            super
          ensure
            ActiveSupport::IsolatedExecutionState[PASSED_KEY] = passed
          end
        rescue FeatureDisabled => e
          MCP.feature_disabled(e)
        end
      end

      # The first required flag that is off, as a FeatureDisabled, or nil.
      # `context:` replaces each requirement's `for:`; `client:` replaces its
      # `client:`. A nil `actor:` resolves through `config.actor_resolver`.
      def standard_flags_disabled(actor: nil, context: nil, client: nil)
        actor = Gated.actor(actor)
        self.class.standard_flags_requirements.each do |requirement|
          target = context.nil? ? standard_flags_resolve(requirement.target, actor, default: actor) : context
          calling = client.nil? ? standard_flags_resolve(requirement.client, actor) : client
          next if StandardFlags.reader(for: Context.wrap(target, client: calling)).enabled?(requirement.key)

          return FeatureDisabled.new(requirement.key, feature: FeatureDisabled.feature_name(requirement.key, audience: AUDIENCE))
        end
        nil
      end

      private

      def standard_flags_resolve(value, actor, default: nil)
        return default if value.nil?
        return value unless value.respond_to?(:call)
        return value.call(actor) unless value.is_a?(Proc)

        value.arity.zero? ? instance_exec(&value) : instance_exec(actor, &value)
      end
    end
  end
end
