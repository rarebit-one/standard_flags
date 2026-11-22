module StandardFlags
  # The evaluation layers, walked top to bottom until one answers. The order
  # is fixed and gates are never OR'd together:
  #
  #   1. TestOverride — `with_flag` and friends; inert outside tests.
  #   2. Guard        — `forbidden_in:` forces the off value.
  #   3. EnvPin       — STANDARD_FLAGS_<KEY>, then legacy `env:` names.
  #   4. CodeDefault  — the registry default for the current environment.
  #
  # Test overrides beat guards, so a spec proving a `forbidden_in:` guard
  # must use a real ENV pin, not `with_flag`.
  #
  # Runtime rules (deny, allow, cohorts, percentages) slot in between 3 and 4,
  # so an ENV pin keeps beating the database and works with it down.
  module Resolvers
    Request = Data.define(:definition, :context, :env_name, :env)

    class TestOverride
      def call(request)
        return unless Testing.active?

        value = Testing.override_for(request.definition.key)
        return if value.equal?(Testing::NONE)

        Evaluation.build(request.definition, value, reason: Reason::STATIC)
      end
    end

    class Guard
      def call(request)
        definition = request.definition
        return unless definition.forbidden_in?(request.env_name)

        pin = ::StandardFlags::EnvPin.scan(definition, request.env).pin
        report(definition, request.env_name, pin) if pin && pin.value != definition.off_value
        Evaluation.build(definition, definition.off_value, reason: Reason::DISABLED)
      end

      private

      def report(definition, env_name, pin)
        Reporting.once(:forbidden, definition.key) do
          Reporting.instrument(:forbidden, key: definition.key, env: env_name, env_var: pin.var)
          Reporting.report(
            ForbiddenPin.new("#{pin.var} pins :#{definition.key} on in #{env_name}, where it is forbidden; forced off"),
            flag: definition.key.to_s, env_var: pin.var
          )
        end
      end
    end

    class EnvPin
      def call(request)
        definition = request.definition
        scan = ::StandardFlags::EnvPin.scan(definition, request.env)
        scan.rejected.each { |var| report_rejected(definition, var) }
        scan.legacy.each { |var| report_legacy(definition, var, shadowed: scan.shadowed_legacy.include?(var)) }
        return unless scan.pin

        Evaluation.build(definition, scan.pin.value, reason: reason(definition, scan.pin), source_env_var: scan.pin.var)
      end

      private

      def reason(definition, pin)
        definition.kill_switch? && pin.value == false ? Reason::KILL_SWITCH : Reason::ENV_PIN
      end

      def report_rejected(definition, var)
        Reporting.once(:pin_rejected, definition.key, var) do
          Reporting.instrument(:pin_rejected, key: definition.key, env_var: var, expected: definition.allowed_values)
          Reporting.report(
            PinRejected.new("#{var} is not a valid value for :#{definition.key} " \
                            "(expected one of #{definition.allowed_values.join('/')}); ignored"),
            flag: definition.key.to_s, env_var: var
          )
        end
      end

      def report_legacy(definition, var, shadowed:)
        Reporting.once(:legacy_env, definition.key, var) do
          Reporting.instrument(:legacy_env,
            key: definition.key, env_var: var, canonical: definition.canonical_env_var, shadowed: shadowed)
        end
      end
    end

    class CodeDefault
      def call(request)
        definition = request.definition
        Evaluation.build(definition, definition.default_for(request.env_name), reason: Reason::DEFAULT)
      end
    end

    CHAIN = [
      TestOverride.new,
      Guard.new,
      EnvPin.new,
      # Runtime rules go here.
      CodeDefault.new
    ].freeze
  end
end
