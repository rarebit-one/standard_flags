require "date"

module StandardFlags
  # The flags an app declares in config/flags.rb. Immutable once built;
  # `StandardFlags.define` builds a new one and swaps it in.
  class Registry
    Unit = Data.define(:name, :resolver)
    Tombstone = Data.define(:key, :removed)

    attr_reader :tombstones, :units

    def self.empty
      new(flags: {}, tombstones: {}, units: {}, env_resolver: nil)
    end

    def initialize(flags:, tombstones:, units:, env_resolver:)
      @flags = flags.freeze
      @tombstones = tombstones.freeze
      @units = units.freeze
      @env_resolver = env_resolver
      freeze
    end

    def [](key)
      @flags[key.to_sym]
    end

    def key?(key)
      @flags.key?(key.to_sym)
    end

    def tombstoned?(key)
      @tombstones.key?(key.to_sym)
    end

    def keys
      @flags.keys
    end

    def definitions
      @flags.values
    end

    def each(&)
      definitions.each(&)
    end

    def empty?
      @flags.empty?
    end

    # Definitions exposed to `audience`, ordered by wire name.
    def exposed(audience)
      definitions.select { |definition| definition.wire_name(audience) }.sort_by { |d| d.wire_name(audience) }
    end

    def audiences
      definitions.flat_map(&:audiences).uniq.sort
    end

    # The logical environment name ("staging", "production", ...). Apps whose
    # staging boots with RAILS_ENV=production pass their own `env_resolver`.
    def current_env
      (@env_resolver || method(:default_env)).call.to_s
    end

    private

    def default_env
      if defined?(::Rails) && ::Rails.respond_to?(:env)
        ::Rails.env
      else
        ENV.fetch("RAILS_ENV") { ENV.fetch("RACK_ENV", "development") }
      end
    end

    # The DSL evaluated by `StandardFlags.define`.
    class Builder
      def initialize
        @flags = {}
        @tombstones = {}
        @units = {}
        @env_resolver = nil
      end

      def env_resolver(callable = nil, &block)
        callable ||= block
        raise DefinitionError, "env_resolver needs a callable" unless callable.respond_to?(:call)

        @env_resolver = callable
      end

      # `from:` is a lambda over the Context; `resolver:` is any object with
      # `call(context)`. Units are carried in the context now and used for
      # targeting once runtime rules arrive.
      def unit(name, from: nil, resolver: nil)
        callable = from || resolver
        raise DefinitionError, "unit :#{name} needs from: or resolver:" unless callable.respond_to?(:call)
        raise DefinitionError, "unit :#{name} is declared twice" if @units.key?(name.to_sym)

        @units[name.to_sym] = Unit.new(name: name.to_sym, resolver: callable)
      end

      Definition::KINDS.each do |kind|
        define_method(kind) do |key, **attributes|
          add(Definition.new(kind, key, attributes))
        end
      end

      def tombstone(key, removed:)
        key = key.to_sym
        raise DefinitionError, "tombstone :#{key} is declared twice" if @tombstones.key?(key)

        date = Date.iso8601(removed.to_s)
        @tombstones[key] = Tombstone.new(key: key, removed: date)
      rescue Date::Error
        raise DefinitionError, "tombstone :#{key} removed: #{removed.inspect} is not a YYYY-MM-DD date"
      end

      def build
        validate_tombstones!
        validate_units!
        validate_wire_names!
        Registry.new(flags: @flags, tombstones: @tombstones, units: @units, env_resolver: @env_resolver)
      end

      private

      def add(definition)
        raise DefinitionError, "flag :#{definition.key} is declared twice" if @flags.key?(definition.key)

        @flags[definition.key] = definition
      end

      # Keys are immutable and never reused: an old key woken up by a new
      # declaration can switch on code that was meant to be dead.
      def validate_tombstones!
        reused = @flags.keys & @tombstones.keys
        return if reused.empty?

        key = reused.first
        raise DefinitionError,
          "flag :#{key} was removed on #{@tombstones[key].removed.iso8601}; keys are never reused, pick a new one"
      end

      def validate_units!
        @flags.each_value do |definition|
          next if definition.unit.nil? || @units.key?(definition.unit)

          raise DefinitionError, "#{definition.kind} :#{definition.key} uses undeclared unit :#{definition.unit}"
        end
      end

      def validate_wire_names!
        seen = Hash.new { |hash, audience| hash[audience] = {} }
        @flags.each_value do |definition|
          definition.expose.each do |audience, wire|
            if (other = seen[audience][wire])
              raise DefinitionError,
                "wire name #{wire.inspect} for audience :#{audience} is used by both :#{other} and :#{definition.key}"
            end
            seen[audience][wire] = definition.key
          end
        end
      end
    end
  end
end
