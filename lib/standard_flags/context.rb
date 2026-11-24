module StandardFlags
  # Who and what a flag is being evaluated for: one actor per unit, an
  # optional environment override, and the calling client (a
  # StandardFlags::Client: platform, version, build), which runtime rules'
  # client conditions read.
  #
  #   StandardFlags.on?(:new_checkout, for: account)                # a single target
  #   StandardFlags.on?(:new_checkout, for: { account: account, organization: org })
  #   StandardFlags.on?(:new_checkout, for: StandardFlags::Context.new(env: "staging"))
  #   StandardFlags.on?(:new_checkout, for: StandardFlags::Context.wrap(account, client: client))
  #
  # `client:` takes a Client or a Hash (`{ platform:, version:, build: }`);
  # `context.client[:platform]` reads the value as given either way.
  #
  # The memo key covers env, target, actors and client, so two clients in one
  # unit of work never share an answer once rules target platform or version.
  #
  # A unit's `from:` lambda receives the context: actors passed by unit name
  # read as methods (`ctx.account`), and anything else is asked of the single
  # target (`ctx.organization` calls `target.organization`).
  class Context
    attr_reader :actors, :target, :env, :client, :cache_key

    # A Context from a Context, a Hash of actors, a single target or nil.
    # `client:` (a Client or a Hash) replaces the context's client when
    # given and not empty; nil and `{}` both leave it as it is.
    def self.wrap(value, client: nil)
      context =
        case value
        when Context then value
        when nil then empty
        when Hash then new(actors: value)
        else new(target: value)
        end
      client.nil? || (client.respond_to?(:empty?) && client.empty?) ? context : context.with_client(client)
    end

    def self.empty
      @empty ||= new
    end

    def initialize(actors: {}, target: nil, env: nil, client: {})
      @actors = actors.transform_keys(&:to_sym).freeze
      @target = target
      @env = env&.to_s
      @client = Client.wrap(client)
      @cache_key = [
        @env,
        identity(@target),
        @actors.sort.map { |unit, actor| [ unit, identity(actor) ] },
        @client.to_h.sort
      ].freeze
      freeze
    end

    # The same context for another client.
    def with_client(client)
      client = Client.wrap(client)
      return self if client == @client

      self.class.new(actors: actors, target: target, env: env, client: client)
    end

    def actor(unit)
      unit = unit.to_sym
      return actors[unit] if actors.key?(unit)

      target.public_send(unit) if target.respond_to?(unit)
    end

    def respond_to_missing?(name, include_private = false)
      actors.key?(name) || target.respond_to?(name) || super
    end

    def method_missing(name, *args, &block)
      return super unless args.empty? && block.nil? && respond_to_missing?(name)

      actor(name)
    end

    private

    # An unsaved record (nil id) falls back to object identity, so two of
    # them never share a memoised answer.
    def identity(object)
      case object
      when nil, String, Symbol, Numeric, true, false then object
      else
        id = object.id if object.respond_to?(:id)
        [ object.class.name, id.nil? ? object.object_id : id ]
      end
    end
  end
end
