require "date"

module StandardFlags
  # One declared flag. Built by Registry::Builder and immutable afterwards.
  #
  # Construction validates everything that can be checked from the
  # declaration alone and raises DefinitionError; cross-flag checks (unit
  # references, tombstones, wire-name clashes) live in Registry::Builder.
  class Definition
    KINDS = %i[flag kill_switch mode experiment compat].freeze
    BOOLEAN_KINDS = %i[flag kill_switch compat].freeze

    PRESETS = {
      sensor: %i[off sensor on],
      cutover: %i[off allowlist all],
      shadow: %i[off shadow enforce]
    }.freeze

    COMMON_ATTRIBUTES = %i[owner description default env inverted legacy_parser legacy_true forbidden_in fail
                           expose min_client unit].freeze
    ATTRIBUTES = {
      flag: COMMON_ATTRIBUTES + %i[remove_by final permanent bucketing],
      kill_switch: COMMON_ATTRIBUTES,
      mode: COMMON_ATTRIBUTES + %i[preset values remove_by final permanent bucketing],
      experiment: COMMON_ATTRIBUTES + %i[variants bucketing],
      compat: COMMON_ATTRIBUTES + %i[remove_by until_clients]
    }.freeze

    KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/
    ENV_VAR_FORMAT = /\A[A-Z][A-Z0-9_]*\z/
    WIRE_FORMAT = /\A[A-Za-z][A-Za-z0-9_]*\z/
    HASH_VERSIONS = [ 1, 2 ].freeze

    # How legacy `env:` values are read. :strict is the one strict parser;
    # :exact reproduces a hand-written `ENV["X"] == "on"` reader. Neither
    # applies to the canonical STANDARD_FLAGS_<KEY> pin, which is always
    # strict.
    LEGACY_PARSERS = %i[strict exact].freeze
    DEFAULT_LEGACY_TRUE = %w[on].freeze

    # A declared `bucketing: { version:, salt: }`, for a flag migrated from
    # another system that must keep its old buckets. Copied into the flag's
    # runtime rule when the rule is first created.
    Bucketing = Data.define(:version, :salt)

    attr_reader :key, :kind, :owner, :description, :env, :inverted, :forbidden_in,
                :expose, :exposure, :min_client, :unit, :remove_by, :final, :values, :variants, :permanent,
                :bucketing, :legacy_parser, :legacy_true, :until_clients

    def initialize(kind, key, attributes)
      @kind = kind.to_sym
      raise DefinitionError, "unknown flag kind #{kind.inspect}" unless KINDS.include?(@kind)

      @key = normalize_key(key)
      check_attributes!(attributes)
      assign(attributes)
      validate!
      freeze
    end

    def boolean?
      BOOLEAN_KINDS.include?(kind)
    end

    def mode?
      kind == :mode
    end

    def experiment?
      kind == :experiment
    end

    def kill_switch?
      kind == :kill_switch
    end

    # A `flag` or `mode` declared `permanent: true`: a standing switch (an
    # environment permission, say) with no remove_by: or final:, never stale.
    def permanent?
      permanent
    end

    # Every value this flag can take, in declared order.
    def allowed_values
      if boolean? then [ true, false ]
      elsif mode? then values
      else variants
      end
    end

    # The value a guard forces: false, the first mode value, or the first
    # (control) variant.
    def off_value
      boolean? ? false : allowed_values.first
    end

    # The value when nothing else applies and no `default:` is declared.
    def kind_default
      case kind
      when :kill_switch, :compat then true
      when :flag then false
      else allowed_values.first
      end
    end

    def default_for(env_name)
      return kind_default if @default.nil?
      return @default unless @default.is_a?(Hash)

      @default.fetch(env_name.to_s) { kind_default }
    end

    # The declared default as written (scalar or per-environment Hash with
    # String keys), for the manifest.
    def declared_default
      @default
    end

    # The value returned when evaluation raises. Kill switches fail open.
    def fail_value
      @fail.nil? ? kind_default : @fail
    end

    def variant_for(value)
      return nil if value.nil?
      return value.to_s unless boolean?

      value ? "on" : "off"
    end

    # The value a stored runtime string stands for ("on"/"off", a mode value,
    # a variant), or Parser::INVALID when this flag can't take it.
    def value_from_wire(text)
      return Parser::INVALID unless text.is_a?(String)
      return { "on" => true, "off" => false }.fetch(text, Parser::INVALID) if boolean?

      allowed_values.find { |value| value.to_s == text } || Parser::INVALID
    end

    # The canonical pin, STANDARD_FLAGS_<KEY>. It is never inverted.
    def canonical_env_var
      "STANDARD_FLAGS_#{key.to_s.upcase}"
    end

    def forbidden_in?(env_name)
      forbidden_in.include?(env_name.to_s)
    end

    # The wire name `audience` sees (the first one listed when it has
    # aliases), or nil when the flag isn't exposed to it.
    def wire_name(audience)
      expose[audience.to_sym]
    end

    # Every wire name `audience` sees, in declared order: one, or several
    # aliases that all serve the same evaluation. Empty when not exposed.
    def wire_names(audience)
      exposure.fetch(audience.to_sym, [])
    end

    def audiences
      expose.keys
    end

    # Whether a client may receive this flag, given `min_client:` (never set
    # on a kill switch). A flag
    # without one goes to every client. With one, it goes to a client on a
    # platform the declaration doesn't list, or on a listed platform at or
    # above that minimum; an unknown platform, or a listed platform with an
    # unknown version, never receives it.
    def deliverable_to?(client)
      return true if min_client.empty?

      platform = client.platform
      return false if platform.nil?

      minimum = min_client[platform]
      return true if minimum.nil?

      !client.version.nil? && client.version >= minimum
    end

    # A compat flag's window: `until_clients:` lists, per platform, the first
    # client version that no longer needs the shim. Empty for other flags.
    def compat_window?
      !until_clients.empty?
    end

    # Permanent flags have no remove_by:, so they are never stale.
    def stale?(today = Date.today)
      !remove_by.nil? && remove_by < today
    end

    def inspect
      "#<StandardFlags::Definition #{kind} :#{key}>"
    end

    private

    def normalize_key(key)
      key = key.to_s
      raise DefinitionError, "flag key #{key.inspect} must match #{KEY_FORMAT.inspect}" unless key.match?(KEY_FORMAT)

      key.to_sym
    end

    def check_attributes!(attributes)
      unknown = attributes.keys.map(&:to_sym) - ATTRIBUTES.fetch(kind)
      return if unknown.empty?

      raise DefinitionError, "#{kind} :#{key} has unknown attribute(s): #{unknown.map(&:inspect).join(', ')}"
    end

    def assign(attributes)
      attributes = attributes.transform_keys(&:to_sym)
      @owner = attributes[:owner]&.to_s
      @description = attributes[:description]&.to_s
      @env = Array(attributes[:env]).map(&:to_s).freeze
      @inverted = attributes.fetch(:inverted, false)
      @legacy_parser = attributes.fetch(:legacy_parser, :strict)
      @legacy_parser = @legacy_parser.to_sym if @legacy_parser.respond_to?(:to_sym)
      @legacy_true = normalize_legacy_true(attributes)
      @forbidden_in = Array(attributes[:forbidden_in]).map(&:to_s).freeze
      @exposure = normalize_expose(attributes[:expose])
      @expose = @exposure.transform_values(&:first).freeze
      @min_client = normalize_min_client(attributes[:min_client])
      @until_clients = normalize_until_clients(attributes[:until_clients])
      @unit = attributes[:unit]&.to_sym
      @remove_by = parse_date(attributes[:remove_by], :remove_by)
      @values = resolve_values(attributes)
      @variants = attributes[:variants] && Array(attributes[:variants]).map(&:to_s).freeze
      fail!("variants: must list at least two unique variants") if experiment? && invalid_variants?
      @default = normalize_default(attributes[:default])
      @fail = attributes.key?(:fail) ? coerce(attributes[:fail], :fail) : nil
      @final = attributes.key?(:final) ? coerce(attributes[:final], :final) : nil
      @permanent = attributes.fetch(:permanent, false)
      @bucketing = normalize_bucketing(attributes[:bucketing])
    end

    def validate!
      fail!("is missing owner:") if owner.nil? || owner.strip.empty?
      validate_lifecycle!
      validate_env!
      validate_legacy_parser!
      validate_forbidden_in!
      fail!("bucketing: needs a unit: to bucket") if bucketing && unit.nil?
    end

    # Flags must declare a lifecycle: remove_by: and final:, or permanent:.
    # Modes may: remove_by: and final: together, or permanent:, or neither.
    def validate_lifecycle!
      fail!("permanent: must be true or false") unless [ true, false ].include?(permanent)
      return validate_permanent! if permanent

      case kind
      when :flag
        fail!("is missing remove_by: (release flags are temporary; declare permanent: true for a standing switch)") if remove_by.nil?
        fail!("is missing final: (the value it settles on when removed)") if @final.nil?
      when :mode
        fail!("has remove_by: but is missing final: (the value it settles on when removed)") if remove_by && @final.nil?
        fail!("has final: but is missing remove_by:") if remove_by.nil? && !@final.nil?
      end
    end

    def validate_permanent!
      fail!("is permanent: and cannot have remove_by:") unless remove_by.nil?
      fail!("is permanent: and cannot have final:") unless @final.nil?
    end

    def validate_env!
      env.each do |name|
        fail!("env: #{name.inspect} is not an environment variable name") unless name.match?(ENV_VAR_FORMAT)
        fail!("env: #{name.inspect} is the canonical name; list only legacy names") if name == canonical_env_var
      end
      fail!("inverted: must be true or false") unless [ true, false ].include?(inverted)
      fail!("inverted: needs a legacy env: name") if inverted && env.empty?
      fail!("inverted: only applies to on/off kinds") if inverted && !boolean?
    end

    def validate_forbidden_in!
      forbidden_in.each do |env_name|
        next if default_for(env_name) == off_value

        fail!("defaults to #{default_for(env_name).inspect} in #{env_name}, where it is forbidden_in:")
      end
    end

    def validate_legacy_parser!
      fail!("legacy_parser: must be one of #{LEGACY_PARSERS.inspect}") unless LEGACY_PARSERS.include?(legacy_parser)
      fail!("legacy_parser: needs a legacy env: name") if legacy_parser == :exact && env.empty?
      return if @legacy_true.nil? || @legacy_true.equal?(DEFAULT_LEGACY_TRUE)

      fail!("legacy_true: needs legacy_parser: :exact") unless legacy_parser == :exact
      fail!("legacy_true: only applies to on/off kinds") unless boolean?
      return unless @legacy_true.empty? || @legacy_true.any? { |word| word.strip.empty? }

      fail!("legacy_true: must list at least one non-blank value")
    end

    # The exact legacy values that mean on, for an on/off kind read with
    # `legacy_parser: :exact`; nil otherwise (unless declared, so validation
    # can reject it).
    def normalize_legacy_true(attributes)
      return Array(attributes[:legacy_true]).map(&:to_s).freeze if attributes.key?(:legacy_true)

      DEFAULT_LEGACY_TRUE if @legacy_parser == :exact && boolean?
    end

    def invalid_variants?
      variants.nil? || variants.size < 2 || variants.uniq.size != variants.size
    end

    def resolve_values(attributes)
      return nil unless mode?

      preset = attributes[:preset]
      explicit = attributes[:values]
      fail!("needs exactly one of preset: or values:") if preset.nil? == explicit.nil?

      if preset
        PRESETS.fetch(preset.to_sym) { fail!("preset: must be one of #{PRESETS.keys.inspect}") }
      else
        list = Array(explicit).map(&:to_sym)
        fail!("values: must list at least two unique values") if list.size < 2 || list.uniq.size != list.size
        list.freeze
      end
    end

    def normalize_default(default)
      return nil if default.nil?
      return coerce(default, :default) unless default.is_a?(Hash)

      default.to_h { |env_name, value| [ env_name.to_s, coerce(value, :default) ] }.freeze
    end

    def normalize_bucketing(bucketing)
      return nil if bucketing.nil?
      fail!("bucketing: must be a Hash with version: and salt:") unless bucketing.is_a?(Hash)

      bucketing = bucketing.transform_keys(&:to_sym)
      unknown = bucketing.keys - %i[version salt]
      fail!("bucketing: has unknown key(s): #{unknown.map(&:inspect).join(', ')}") unless unknown.empty?
      version = bucketing[:version]
      salt = bucketing[:salt]
      fail!("bucketing: version: must be one of #{HASH_VERSIONS.inspect}") unless HASH_VERSIONS.include?(version)
      fail!("bucketing: salt: must be a non-blank String") unless salt.is_a?(String) && !salt.strip.empty?

      Bucketing.new(version: version, salt: salt.dup.freeze)
    end

    # `{ audience => [wire, ...] }`. A Hash value may list several wire
    # names (aliases) for one audience.
    def normalize_expose(expose)
      pairs =
        case expose
        when nil then {}
        when Hash then expose
        else Array(expose).to_h { |audience| [ audience, key ] }
        end

      pairs.to_h do |audience, wires|
        wires = (wires.is_a?(Array) ? wires : [ wires ]).map(&:to_s)
        fail!("expose: lists no wire name for :#{audience}") if wires.empty?
        wires.each do |wire|
          fail!("expose: wire name #{wire.inspect} must match #{WIRE_FORMAT.inspect}") unless wire.match?(WIRE_FORMAT)
        end
        fail!("expose: lists a wire name twice for :#{audience}") unless wires.uniq.size == wires.size
        [ audience.to_sym, wires.freeze ]
      end.freeze
    end

    # `{ "platform" => Version }`: the oldest client build per platform that
    # may receive this flag.
    def normalize_min_client(min_client)
      return {}.freeze if min_client.nil?
      fail!("min_client: must be a Hash of platform => version") unless min_client.is_a?(Hash)
      fail!("min_client: only applies to a flag with expose:") if @exposure.empty?
      # A withheld entry means the client's code default, which for a kill
      # switch is "available": an old client would never see it pulled.
      fail!("min_client: can't be used on a kill switch; a kill switch must reach every client") if kill_switch?

      Definition.client_versions(min_client) { |message| fail!("min_client: #{message}") }
    end

    # `{ "platform" => Version }`: a compat flag's window. Its evaluations
    # are counted (`config.track_compat`) and `flags:stale` reports it once
    # every listed platform is past its version and it has gone unused.
    def normalize_until_clients(until_clients)
      return {}.freeze if until_clients.nil?
      fail!("until_clients: must be a Hash of platform => version") unless until_clients.is_a?(Hash)

      Definition.client_versions(until_clients) { |message| fail!("until_clients: #{message}") }
    end

    # Casts a declared value to this kind's type, raising for anything outside
    # the declared set.
    def coerce(value, attribute)
      cast =
        if boolean? then value
        elsif mode? then value.respond_to?(:to_sym) ? value.to_sym : value
        else value.to_s
        end
      return cast if allowed_values.include?(cast)

      fail!("#{attribute}: #{value.inspect} is not one of #{allowed_values.inspect}")
    end

    def parse_date(value, attribute)
      return nil if value.nil?
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue Date::Error
      fail!("#{attribute}: #{value.inspect} is not a YYYY-MM-DD date")
    end

    def fail!(message)
      raise DefinitionError, "#{kind} :#{key} #{message}"
    end

    # `{ platform => version }` (a min_client: or until_clients: Hash) as
    # `{ "platform" => Version }`. Platforms must be in
    # `config.client_platforms`; versions must parse. Yields a message and
    # expects the block to raise.
    def self.client_versions(pairs)
      platforms = StandardFlags.config.client_platforms.map { |name| name.to_s.downcase }
      yield "must name at least one platform" if pairs.empty?
      pairs.to_h do |platform, version|
        name = platform.to_s.downcase
        yield "platform #{platform.inspect} is not one of config.client_platforms #{platforms.inspect}" unless platforms.include?(name)
        parsed = version.is_a?(String) ? Version.parse(version) : nil
        yield "#{version.inspect} for #{name} is not a version (\"0.4.0\")" if parsed.nil?
        [ name.freeze, parsed ]
      end.freeze
    end
  end
end
