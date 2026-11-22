module StandardFlags
  # Who and what a flag is being evaluated for: one actor per unit, an
  # optional environment override, and the calling client (platform, version,
  # build). Runtime rules and client targeting read these in later phases;
  # today they only feed the per-unit-of-work memo key.
  #
  #   StandardFlags.on?(:new_checkout, for: account)                # a single target
  #   StandardFlags.on?(:new_checkout, for: { account: account, organization: org })
  #   StandardFlags.on?(:new_checkout, for: StandardFlags::Context.new(env: "staging"))
  #
  # A unit's `from:` lambda receives the context: actors passed by unit name
  # read as methods (`ctx.account`), and anything else is asked of the single
  # target (`ctx.organization` calls `target.organization`).
  class Context
    attr_reader :actors, :target, :env, :client, :cache_key

    def self.wrap(value)
      case value
      when Context then value
      when nil then empty
      when Hash then new(actors: value)
      else new(target: value)
      end
    end

    def self.empty
      @empty ||= new
    end

    def initialize(actors: {}, target: nil, env: nil, client: {})
      @actors = actors.transform_keys(&:to_sym).freeze
      @target = target
      @env = env&.to_s
      @client = client.transform_keys(&:to_sym).freeze
      @cache_key = [ @env, identity(@target), @actors.sort.map { |unit, actor| [ unit, identity(actor) ] } ].freeze
      freeze
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

    def identity(object)
      case object
      when nil, String, Symbol, Numeric, true, false then object
      else [ object.class.name, object.respond_to?(:id) ? object.id : object.object_id ]
      end
    end
  end
end
