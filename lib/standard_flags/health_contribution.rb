module StandardFlags
  # Announces StandardFlags to standard_health 0.9+ through its load hook, so
  # an app that calls `register_default_checks` gets the flags check without
  # registering it, and `/diagnostics/env` lists the pins that must stay
  # unset. Neither gem depends on the other: with standard_health absent (or
  # older than 0.9) the hook never runs, and apps register
  # StandardFlags::HealthCheck by hand as before.
  #
  # Env vars contributed: the canonical STANDARD_FLAGS_<KEY> pin and every
  # legacy `env:` name of each `forbidden_in:` flag, as `forbidden` in those
  # environments when they pin the flag on. Other pins are optional, which
  # EnvSpec has no level for, so they are not declared. An app's own
  # env_spec entry for a name overrides the contribution. The declarations
  # are re-contributed whenever the registry is (re)defined.
  #
  # @api private
  module HealthContribution
    CONTRIBUTOR = "standard_flags".freeze
    CHECK_NAME = :standard_flags
    HOOK = proc { |health| HealthContribution.register!(health) }

    class << self
      def register!(health)
        @health = health
        health.contribute_check CHECK_NAME, "StandardFlags::HealthCheck", critical: false
        contribute_env_vars(StandardFlags.registry)
      end

      def refresh!(registry)
        contribute_env_vars(registry) if @health
      end

      # Forget the yielded object (specs only).
      def reset!
        @health = nil
      end

      def env_entries(registry, env: -> { StandardFlags.config.env_source })
        registry.definitions.reject { |definition| definition.forbidden_in.empty? }.flat_map do |definition|
          pinned_on = -> { pinned_on?(definition, env.call) }
          ([ definition.canonical_env_var ] + definition.env).map do |name|
            { name: name.to_sym, in: definition.forbidden_in.dup,
              description: "Pins :#{definition.key}, which is forbidden_in: these environments", if: pinned_on }
          end
        end
      end

      private

      def contribute_env_vars(registry)
        entries = env_entries(registry)
        @health.contribute_env_vars(CONTRIBUTOR) do
          entries.each { |entry| forbidden entry[:name], in: entry[:in], description: entry[:description], if: entry[:if] }
        end
      rescue StandardError => e
        warn "[standard_flags] standard_health env contribution failed: #{e.class}: #{e.message}"
      end

      def pinned_on?(definition, env)
        pin = EnvPin.scan(definition, env).pin
        !pin.nil? && pin.value != definition.off_value
      end
    end
  end
end
