module StandardFlags
  # A client audience: a name flags `expose:` wire names to (`:web`,
  # `:mobile`), and whether it is served before authentication.
  #
  #   config.audiences = { web: {}, mobile: {}, pre_auth: { public: true, unit: :install } }
  #
  # A `public: true` audience is the only kind an `anonymous: true` OFREP
  # controller serves. Its flags may target by client attributes, and by
  # `unit:` (a declared unit) whose key the request's `targetingKey` names;
  # every other unit resolves to nothing for it, and segments are skipped.
  #
  # Without `config.audiences`, every audience a flag exposes to is a
  # private audience, which is how 0.2.x behaved.
  Audience = Data.define(:name, :public, :unit) do
    # `{ name => Audience }` from `config.audiences` (an Array of names or a
    # Hash of name => options), or nil for nil.
    def self.normalize(value)
      return nil if value.nil?

      pairs =
        case value
        when Hash then value
        when Array then value.to_h { |name| [ name, {} ] }
        else raise ArgumentError, "config.audiences must be an Array of names or a Hash of name => options"
        end
      pairs.to_h { |name, options| [ name.to_sym, build(name.to_sym, options) ] }.freeze
    end

    def self.build(name, options)
      raise ArgumentError, "audience :#{name} options must be a Hash" unless options.nil? || options.is_a?(Hash)

      options = (options || {}).transform_keys(&:to_sym)
      unknown = options.keys - %i[public unit]
      raise ArgumentError, "audience :#{name} has unknown option(s): #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

      public = options.fetch(:public, false)
      raise ArgumentError, "audience :#{name} public: must be true or false" unless [ true, false ].include?(public)

      unit = options[:unit]&.to_sym
      raise ArgumentError, "audience :#{name} unit: only applies to a public: true audience" if unit && !public

      new(name: name, public: public, unit: unit)
    end

    def public?
      public
    end
  end
end
