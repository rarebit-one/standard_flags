require "time"

module StandardFlags
  # Operator tools for an agent or chat surface, one class per tool, with no
  # dependency on any MCP framework. Each instance has `name`,
  # `description`, `input_schema` (a JSON Schema Hash) and
  # `call(arguments, actor:)`, which returns a JSON-safe Hash with String
  # keys, or `{ "error" => { "code" =>, "message" => } }`:
  #
  #   StandardFlags::MCP.tools.each do |tool|
  #     registry.register(name: tool.name, description: tool.description, schema: tool.input_schema) do |args, user|
  #       tool.call(args, actor: user)
  #     end
  #   end
  #
  # Reads (ListFlags, GetFlag, ListMembers, ListCohorts, GetCohort) ask
  # `config.authorize` for "flags:read"; writes go through
  # StandardFlags::Operations, which authorise, refuse pins, validate and
  # audit, and need `reason`. A failed operation's error code is the
  # Result's (`pinned_by_env`, `stale_revision`, `unauthorized`, ...).
  #
  # Unit keys stay masked (`•••4567`) unless ListMembers is called with
  # `reveal: true` by an actor allowed "flags:write" on the target; a reveal
  # is audited, with counts only. GetFlag's `unit_key` (is this unit a
  # member?) is a reveal too: flags:write, a reason, and a
  # `standard_flags.flag.probed` row.
  #
  # `client:` (a StandardFlags::Client, a Hash, or a lambda taking the
  # actor) is the client ListFlags and GetFlag evaluate for; by default they
  # evaluate with no client.
  #
  # An app's own tools can be gated on flags with StandardFlags::MCP::Gated;
  # `MCP.visible(tools, actor:)` filters a tool list for `tools/list`.
  #
  # One instance may serve every call, from any thread: the instance is
  # frozen, and each call runs on its own copy, which holds that call's
  # actor, arguments and store load. Operator reads never mark a rule as
  # evaluated, so `flags:stale` still sees flags nothing uses.
  module MCP
    # A tool-level failure, returned as the error Hash.
    class ToolError < StandardFlags::Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    MASK = "•••".freeze

    module_function

    # One instance of every tool. `registry:` pins a registry (specs);
    # by default each call reads StandardFlags.registry, so a code reload
    # is picked up.
    def tools(registry: nil, client: nil)
      TOOLS.map { |klass| klass.new(registry: registry, client: client) }
    end

    # The tool called `name`, or nil.
    def tool(name, registry: nil, client: nil)
      klass = TOOLS.find { |candidate| candidate.tool_name == name.to_s }
      klass&.new(registry: registry, client: client)
    end

    # The tools to list for `actor`: every tool, less the gated ones
    # (StandardFlags::MCP::Gated) with a required flag off. `context:`
    # evaluates every gate for that context instead of each one's `for:`;
    # `client:` overrides each gate's client.
    #
    #   StandardFlags::MCP.visible(app_tools + StandardFlags::MCP.tools, actor: current_user,
    #                              client: StandardFlags::Client.from_headers(request.headers))
    def visible(tools, actor: nil, context: nil, client: nil)
      tools.reject do |tool|
        tool.respond_to?(:standard_flags_disabled) &&
          tool.standard_flags_disabled(actor: actor, context: context, client: client)
      end
    end

    # The tool error for a StandardFlags::FeatureDisabled.
    def feature_disabled(error)
      { "error" => { "code" => "feature_disabled", "message" => error.message.to_s } }
    end

    # A unit key as operators see it by default: the last four characters
    # (fewer for short keys, so at least half stays hidden), after a mask.
    def mask(unit_key)
      text = unit_key.to_s
      visible = [ 4, text.length / 2 ].min
      visible.zero? ? MASK : "#{MASK}#{text[-visible..]}"
    end

    # Symbols become Strings, Times ISO 8601, Hash keys Strings.
    def json(value)
      case value
      when Hash then value.to_h { |k, v| [ k.to_s, json(v) ] }
      when Array then value.map { |v| json(v) }
      when Symbol then value.to_s
      when Time, DateTime then value.utc.iso8601
      when Date then value.iso8601
      when String, Integer, Float, true, false, nil then value
      else value.to_s
      end
    end

    # Shared by every tool: the class-level description, argument checks
    # against the schema, actor resolution and the read policy.
    class Tool
      TYPES = {
        "string" => [ String, Symbol ], "integer" => [ Integer ], "boolean" => [ true.class, false.class ],
        "array" => [ Array ], "object" => [ Hash ], "null" => [ NilClass ]
      }.freeze

      class << self
        def tool_name(name = nil)
          @tool_name = name.to_s.freeze if name
          @tool_name
        end

        def description(text = nil)
          @description = text.freeze if text
          @description
        end

        # Properties, then which are required. additionalProperties is
        # always false.
        def schema(properties, required: [])
          @input_schema = MCP.json({ type: "object", properties: properties, required: required,
                                     additionalProperties: false }).freeze
        end

        def input_schema
          @input_schema
        end
      end

      def initialize(registry: nil, client: nil)
        unless client.nil? || client.is_a?(Client) || client.is_a?(Hash) || client.respond_to?(:call)
          raise ArgumentError, "client: must be a StandardFlags::Client, a Hash or a callable"
        end

        @registry = registry
        @client = client unless client.nil?
        freeze
      end

      def name = self.class.tool_name
      def description = self.class.description
      def input_schema = self.class.input_schema

      # Runs on a copy (`dup` of a frozen object is not frozen), so nothing
      # one call sets is seen by another.
      def call(arguments, actor:)
        dup.__send__(:invoke, arguments, actor)
      end

      private

      attr_reader :actor

      def invoke(arguments, actor)
        args = check_arguments!(arguments || {})
        @actor = actor || StandardFlags.config.actor_resolver&.call
        raise ToolError.new(:actor_missing, "no actor: pass actor:, or configure config.actor_resolver") if @actor.nil?

        MCP.json(Runtime.tracker.untracked { perform(args) })
      rescue ToolError => e
        error(e.code, e.message)
      rescue StandardError => e
        Reporting.report(Error.new("#{name} failed: #{e.class}"), tool: name)
        error(:error, "#{name} failed: #{e.class}")
      end

      def registry
        @registry || StandardFlags.registry
      end

      # What reads evaluate for: no unit, and the configured client.
      def evaluation_context
        return @evaluation_context if defined?(@evaluation_context)

        client = @client.respond_to?(:call) ? call_with_actor(@client) : @client
        @evaluation_context = client.nil? ? Context.empty : Context.new(client: client)
      end

      def call_with_actor(callable)
        callable.is_a?(Proc) && callable.arity.zero? ? callable.call : callable.call(actor)
      end

      def error(code, message)
        { "error" => { "code" => code.to_s, "message" => message.to_s } }
      end

      def check_arguments!(arguments)
        raise ToolError.new(:invalid_arguments, "arguments must be an object") unless arguments.is_a?(Hash)

        args = arguments.transform_keys(&:to_s)
        properties = input_schema["properties"]
        unknown = args.keys - properties.keys
        raise ToolError.new(:invalid_arguments, "unknown argument(s): #{unknown.join(', ')}") unless unknown.empty?

        missing = input_schema["required"] - args.keys
        raise ToolError.new(:invalid_arguments, "missing argument(s): #{missing.join(', ')}") unless missing.empty?

        args.each do |key, value|
          types = Array(properties[key]["type"])
          next if types.any? { |type| TYPES.fetch(type).any? { |klass| value.is_a?(klass) } }

          raise ToolError.new(:invalid_arguments, "#{key} must be #{types.join(' or ')}")
        end
        args
      end

      def allowed?(scope, key)
        StandardFlags.config.authorize.call(actor, scope, key) ? true : false
      rescue StandardError => e
        Reporting.report(e, tool: name)
        false
      end

      def authorize!(scope, key)
        return if allowed?(scope, key)

        raise ToolError.new(:unauthorized, "#{Actor.label(actor)} may not #{scope} #{key.inspect}")
      end

      def definition!(key)
        key = key.to_s.to_sym
        if registry.tombstoned?(key)
          raise ToolError.new(:tombstoned_flag, "flag :#{key} was removed on #{registry.tombstones[key].removed.iso8601}")
        end

        registry[key] || raise(ToolError.new(:unknown_flag, "unknown flag :#{key}"))
      end

      # The ENV pin deciding this flag, as operators see it: the variable's
      # name, never its value.
      def pin(definition)
        pin = EnvPin.scan(definition, StandardFlags.config.env_source).pin
        pin && { env_var: pin.var, label: "Pinned by environment (#{pin.var})" }
      end

      # The stored rules and cohorts, read fresh (not the process cache) once
      # per call, or nil with runtime rules off.
      def loaded
        return @loaded if defined?(@loaded)

        @loaded = Runtime.enabled? ? Runtime.store.load : nil
      rescue StandardError => e
        raise ToolError.new(:store_error, "could not read the store (#{(e.cause_class if e.is_a?(Runtime::StoreError)) || e.class})")
      end

      def store_revision
        Runtime.enabled? ? Runtime.store.revision : nil
      rescue StandardError
        nil
      end

      def rule_for(key)
        loaded&.rules&.find { |rule| rule.key == key.to_sym }
      end

      def rule_state(rule)
        rule && rule.audit_state.merge(revision: rule.lock_version, last_evaluated_at: rule.last_evaluated_at)
      end
    end
  end
end

require "standard_flags/mcp/flags"
require "standard_flags/mcp/writes"
require "standard_flags/mcp/members"
require "standard_flags/mcp/cohorts"
require "standard_flags/mcp/gating"

module StandardFlags
  module MCP
    TOOLS = [ ListFlags, GetFlag, StartFlag, PauseFlag, StopFlag, RampFlag, SetFlagValue,
              ListMembers, AddMembers, RemoveMembers, ListCohorts, GetCohort ].freeze
  end
end
