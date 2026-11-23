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

    COMMON_ATTRIBUTES = %i[owner description default env inverted forbidden_in fail expose unit].freeze
    ATTRIBUTES = {
      flag: COMMON_ATTRIBUTES + %i[remove_by final permanent bucketing],
      kill_switch: COMMON_ATTRIBUTES,
      mode: COMMON_ATTRIBUTES + %i[preset values bucketing],
      experiment: COMMON_ATTRIBUTES + %i[variants bucketing],
      compat: COMMON_ATTRIBUTES + %i[remove_by]
    }.freeze

    KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/
    ENV_VAR_FORMAT = /\A[A-Z][A-Z0-9_]*\z/
    WIRE_FORMAT = /\A[A-Za-z][A-Za-z0-9_]*\z/
    HASH_VERSIONS = [ 1, 2 ].freeze

    # A declared `bucketing: { version:, salt: }`, for a flag migrated from
    # another system that must keep its old buckets. Copied into the flag's
    # runtime rule when the rule is first created.
    Bucketing = Data.define(:version, :salt)

    attr_reader :key, :kind, :owner, :description, :env, :inverted, :forbidden_in,
                :expose, :unit, :remove_by, :final, :values, :variants, :permanent, :bucketing

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

    # A `flag` declared `permanent: true`: a standing switch (an environment
    # permission, say) with no remove_by: or final:, never stale.
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

    def wire_name(audience)
      expose[audience.to_sym]
    end

    def audiences
      expose.keys
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
      @forbidden_in = Array(attributes[:forbidden_in]).map(&:to_s).freeze
      @expose = normalize_expose(attributes[:expose])
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
      validate_flag_lifecycle!
      validate_env!
      validate_forbidden_in!
      fail!("bucketing: needs a unit: to bucket") if bucketing && unit.nil?
    end

    def validate_flag_lifecycle!
      return unless kind == :flag

      fail!("permanent: must be true or false") unless [ true, false ].include?(permanent)
      return validate_permanent! if permanent

      fail!("is missing remove_by: (release flags are temporary; declare permanent: true for a standing switch)") if remove_by.nil?
      fail!("is missing final: (the value it settles on when removed)") if @final.nil?
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

    def normalize_expose(expose)
      pairs =
        case expose
        when nil then {}
        when Hash then expose
        else Array(expose).to_h { |audience| [ audience, key ] }
        end

      pairs.to_h do |audience, wire|
        wire = wire.to_s
        fail!("expose: wire name #{wire.inspect} must match #{WIRE_FORMAT.inspect}") unless wire.match?(WIRE_FORMAT)
        [ audience.to_sym, wire ]
      end.freeze
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
  end
end
