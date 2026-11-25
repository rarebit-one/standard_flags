require "date"

module StandardFlags
  # The flags an app declares in config/flags.rb. Immutable once built;
  # `StandardFlags.define` builds a new one and swaps it in.
  class Registry
    # `key` is the declared `key:` callable, or nil for the default.
    Unit = Data.define(:name, :resolver, :key) do
      # The unit key for one actor (a record or a raw key): the `key:`
      # callable's answer, else `id` for objects that have one, else the value
      # itself, as a String. Blank means missing.
      def key_for(actor)
        return nil if actor.nil?

        raw = if key then key.call(actor)
        elsif actor.respond_to?(:id) then actor.id
        else actor
        end
        text = raw&.to_s
        text unless text.nil? || text.strip.empty?
      end

      # The unit key for a context, through `from:` / `resolver:`.
      def key_from(context)
        key_for(resolver.call(context))
      end
    end
    # A removed key. `serve` keeps client wires answering a static value
    # after the flag is gone (`{ audience => { "wire" => value } }`), until
    # `serve_until` (a Date, served through that day in UTC; required with
    # `serve`) and, per platform, only for clients older than
    # `until_clients` (`{ "platform" => Version }`).
    Tombstone = Data.define(:key, :removed, :serve, :serve_until, :until_clients) do
      def initialize(key:, removed:, serve: {}, serve_until: nil, until_clients: {})
        super
      end

      # Whether the static wires are still served on `today` (a UTC date).
      def serving?(today)
        !serve.empty? && !serve_until.nil? && today <= serve_until
      end

      # Whether the serve block is past `until:` and can be deleted.
      def serve_expired?(today)
        !serve.empty? && !serve_until.nil? && today > serve_until
      end

      # Whether `client` still receives the static wires: a client on a
      # platform `until_clients` lists stops at that version; one with an
      # unknown platform or version keeps receiving them until `until:`.
      # `until_clients` can only stop the wires sooner than `until:`.
      def serves_client?(client)
        platform = client.platform
        cutoff = platform && until_clients[platform]
        cutoff.nil? || client.version.nil? || client.version < cutoff
      end
    end

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

    # A copy in which `unit` resolves every context to `unit_key`, used as
    # given: what one unit gets, asked without its record (the MCP GetFlag
    # tool, the admin page).
    def with_unit_key(unit, unit_key)
      unit = unit.to_sym
      raise ArgumentError, "unknown unit :#{unit}" unless @units.key?(unit)

      probe = Unit.new(name: unit, resolver: ->(_context) { unit_key }, key: nil)
      Registry.new(flags: @flags, tombstones: @tombstones, units: @units.merge(unit => probe), env_resolver: @env_resolver)
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

    # `[[wire, definition], ...]` for `audience`, every alias included,
    # ordered by wire name.
    def wires(audience)
      definitions.flat_map { |definition| definition.wire_names(audience).map { |wire| [ wire, definition ] } }
                 .sort_by(&:first)
    end

    # `[[wire, value, tombstone], ...]`: the static wires removed flags still
    # serve to `audience` (whatever the date), ordered by wire name.
    def deprecated_wires(audience)
      audience = audience.to_sym
      @tombstones.values.flat_map do |tombstone|
        tombstone.serve.fetch(audience, {}).map { |wire, value| [ wire, value, tombstone ] }
      end.sort_by(&:first)
    end

    def audiences
      definitions.flat_map(&:audiences).uniq.sort
    end

    # The Audience named `name`: from `config.audiences` when it is set,
    # else a private audience for any name a flag exposes to. nil when
    # unknown.
    def audience(name)
      name = name.to_sym
      declared = StandardFlags.config.audiences
      return declared[name] if declared

      served = audiences.include?(name) || @tombstones.each_value.any? { |tombstone| tombstone.serve.key?(name) }
      Audience.new(name: name, public: false, unit: nil) if served
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
      # `call(context)`. Runtime rules target a unit by its key: `key:` turns
      # an actor into one (normalising a phone number, say); the default is
      # `record.id.to_s`, or the value itself for anything without an `id`.
      def unit(name, from: nil, resolver: nil, key: nil)
        callable = from || resolver
        raise DefinitionError, "unit :#{name} needs from: or resolver:" unless callable.respond_to?(:call)
        raise DefinitionError, "unit :#{name} is declared twice" if @units.key?(name.to_sym)
        raise DefinitionError, "unit :#{name} key: must respond to call(actor)" unless key.nil? || key.respond_to?(:call)

        @units[name.to_sym] = Unit.new(name: name.to_sym, resolver: callable, key: key)
      end

      Definition::KINDS.each do |kind|
        define_method(kind) do |key, **attributes|
          add(Definition.new(kind, key, attributes))
        end
      end

      # `serve:` keeps a removed flag's client wires answering a static value
      # (`{ audience => { wire => value } }`) until `until:` (a date, served
      # through that day in UTC; required), and, per platform, only for
      # clients below `until_clients:` (`{ platform => version }`), which can
      # stop them sooner but never extend them.
      #
      #   tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } },
      #             until: "2027-03-01", until_clients: { android: "0.6.0" }
      def tombstone(key, removed:, serve: nil, until: nil, until_clients: nil)
        key = key.to_sym
        raise DefinitionError, "tombstone :#{key} is declared twice" if @tombstones.key?(key)

        removed = tombstone_date(key, :removed, removed)
        serve_until = binding.local_variable_get(:until)
        @tombstones[key] = Tombstone.new(key: key, removed: removed, **tombstone_serve(key, removed, serve, serve_until, until_clients))
      end

      def build
        validate_tombstones!
        validate_units!
        validate_audiences!
        validate_wire_names!
        Registry.new(flags: @flags, tombstones: @tombstones, units: @units, env_resolver: @env_resolver)
      end

      private

      def tombstone_date(key, attribute, value)
        Date.iso8601(value.to_s)
      rescue Date::Error
        raise DefinitionError, "tombstone :#{key} #{attribute}: #{value.inspect} is not a YYYY-MM-DD date"
      end

      def tombstone_serve(key, removed, serve, serve_until, until_clients)
        fail = ->(message) { raise DefinitionError, "tombstone :#{key} #{message}" }
        if serve.nil?
          fail.call("until: needs serve:") unless serve_until.nil?
          fail.call("until_clients: needs serve:") unless until_clients.nil?
          return {}
        end

        fail.call("serve: must be a Hash of audience => { wire => value }") unless serve.is_a?(Hash) && !serve.empty?
        fail.call("serve: needs until: (the last day the wire is served; until_clients: can only stop it sooner)") if serve_until.nil?
        statics = serve.to_h do |audience, wires|
          fail.call("serve: for :#{audience} must be a Hash of wire => value") unless wires.is_a?(Hash) && !wires.empty?
          [ audience.to_sym, wires.to_h { |wire, value| tombstone_wire(fail, wire, value) }.freeze ]
        end
        date = serve_until && tombstone_date(key, :until, serve_until)
        fail.call("until: #{date.iso8601} is before removed: #{removed.iso8601}") if date && date < removed
        clients =
          if until_clients.nil? then {}
          elsif until_clients.is_a?(Hash) then Definition.client_versions(until_clients) { |message| fail.call("until_clients: #{message}") }
          else fail.call("until_clients: must be a Hash of platform => version")
          end
        { serve: statics.freeze, serve_until: date, until_clients: clients }
      end

      def tombstone_wire(fail, wire, value)
        wire = wire.to_s
        fail.call("serve: wire name #{wire.inspect} must match #{Definition::WIRE_FORMAT.inspect}") unless wire.match?(Definition::WIRE_FORMAT)
        value = value.to_s if value.is_a?(Symbol)
        fail.call("serve: #{wire} must serve true, false or a String, not #{value.inspect}") unless [ true, false ].include?(value) || value.is_a?(String)
        fail.call("serve: #{wire} must be valid UTF-8") if value.is_a?(String) && !value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        [ wire.freeze, value.is_a?(String) ? value.dup.force_encoding(Encoding::UTF_8).freeze : value ]
      end

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

      # A wire name is unique within an audience across flags, their aliases
      # and tombstones' static wires.
      def validate_wire_names!
        seen = Hash.new { |hash, audience| hash[audience] = {} }
        claim = lambda do |audience, wire, owner|
          if (other = seen[audience][wire])
            raise DefinitionError, "wire name #{wire.inspect} for audience :#{audience} is used by both #{other} and #{owner}"
          end
          seen[audience][wire] = owner
        end
        @flags.each_value do |definition|
          definition.exposure.each do |audience, wires|
            wires.each { |wire| claim.call(audience, wire, ":#{definition.key}") }
          end
        end
        @tombstones.each_value do |tombstone|
          tombstone.serve.each do |audience, wires|
            wires.each_key { |wire| claim.call(audience, wire, "tombstone :#{tombstone.key}") }
          end
        end
      end

      # With `config.audiences` set, every audience used must be declared. A
      # public audience's unit must be declared, and its flags may only use
      # that unit (or none): nothing else is known before authentication.
      def validate_audiences!
        declared = StandardFlags.config.audiences
        return if declared.nil?

        used = @flags.values.flat_map { |definition| definition.audiences.map { |audience| [ audience, ":#{definition.key}" ] } } +
               @tombstones.values.flat_map { |tombstone| tombstone.serve.keys.map { |audience| [ audience, "tombstone :#{tombstone.key}" ] } }
        used.each do |audience, owner|
          next if declared.key?(audience)

          raise DefinitionError, "#{owner} uses audience :#{audience}, which config.audiences doesn't declare"
        end
        declared.each_value { |audience| validate_public_audience!(audience) if audience.public? }
      end

      def validate_public_audience!(audience)
        if audience.unit && !@units.key?(audience.unit)
          raise DefinitionError, "audience :#{audience.name} uses undeclared unit :#{audience.unit}"
        end

        @flags.each_value do |definition|
          next unless definition.audiences.include?(audience.name)
          next if definition.unit.nil? || definition.unit == audience.unit

          raise DefinitionError,
            "#{definition.kind} :#{definition.key} is exposed to public audience :#{audience.name} but uses unit " \
            ":#{definition.unit}; a public audience can only target #{audience.unit ? "unit :#{audience.unit}" : 'no unit'}"
        end
      end
    end
  end
end
