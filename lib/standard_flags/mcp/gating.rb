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
    # `{ "error" => { "code" => "feature_disabled", "message" => "ai_assistant is disabled" } }`
    # without running the tool, and StandardFlags::MCP.visible leaves the
    # tool out of `tools/list`. The message names the flag's wire name, as
    # `requires_flag` in a controller does.
    #
    # `for:` says who the flag is evaluated for: anything `for:` takes
    # elsewhere, or a lambda run in the tool instance that may take the
    # actor. By default it is the actor. `client:` is a StandardFlags::Client,
    # a Hash, or a lambda returning one. The gem's own operator tools are not
    # gated.
    module Gated
      Requirement = Data.define(:key, :target, :client)

      def self.included(base)
        base.extend(ClassMethods)
        base.prepend(Guard)
      end

      module ClassMethods
        def requires_flag(key, for: nil, client: nil)
          (@standard_flags_requirements ||= []) << Requirement.new(key.to_sym, binding.local_variable_get(:for), client)
          self
        end

        # Every requirement, a superclass's first.
        def standard_flags_requirements
          inherited = superclass.respond_to?(:standard_flags_requirements) ? superclass.standard_flags_requirements : []
          inherited + (@standard_flags_requirements || [])
        end
      end

      # Runs before the tool's own `call`.
      module Guard
        def call(*arguments, **options, &block)
          disabled = standard_flags_disabled(actor: options[:actor])
          return MCP.feature_disabled(disabled) if disabled

          super
        end
      end

      # The first required flag that is off, as a FeatureDisabled, or nil.
      # `context:` replaces each requirement's `for:`; `client:` replaces its
      # `client:`.
      def standard_flags_disabled(actor: nil, context: nil, client: nil)
        self.class.standard_flags_requirements.each do |requirement|
          target = context.nil? ? standard_flags_resolve(requirement.target, actor, default: actor) : context
          calling = client.nil? ? standard_flags_resolve(requirement.client, actor) : client
          next if StandardFlags.reader(for: Context.wrap(target, client: calling)).enabled?(requirement.key)

          return FeatureDisabled.new(requirement.key)
        end
        nil
      end

      private

      def standard_flags_resolve(value, actor, default: nil)
        return default if value.nil?
        return value unless value.is_a?(Proc)

        value.arity.zero? ? instance_exec(&value) : instance_exec(actor, &value)
      end
    end
  end
end
