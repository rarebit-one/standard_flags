module StandardFlags
  # The result of evaluating one flag, in the OpenFeature shape.
  #
  # * `value`          — true/false for flag, kill_switch and compat; a Symbol
  #                      for a mode; a String for an experiment.
  # * `variant`        — the value as a string ("on"/"off" for booleans).
  # * `reason`         — one of StandardFlags::Reason.
  # * `error_code`     — one of StandardFlags::ErrorCode, only when reason is ERROR.
  # * `rule_id`        — which part of a runtime rule decided: "allow",
  #                      "deny", "cohort:<key>", "segment:<name>", "percentage",
  #                      "variants", "fallthrough" or "stopped". nil otherwise.
  # * `source_env_var` — the NAME of the environment variable that decided the
  #                      value, never its contents.
  Evaluation = Data.define(:key, :value, :variant, :reason, :error_code, :rule_id, :source_env_var) do
    def self.build(definition, value, reason:, error_code: nil, rule_id: nil, source_env_var: nil)
      new(
        key: definition.key,
        value: value,
        variant: definition.variant_for(value),
        reason: reason,
        error_code: error_code,
        rule_id: rule_id,
        source_env_var: source_env_var
      )
    end

    def self.not_found(key)
      new(
        key: key, value: nil, variant: nil, reason: Reason::ERROR,
        error_code: ErrorCode::FLAG_NOT_FOUND, rule_id: nil, source_env_var: nil
      )
    end

    def error?
      reason == Reason::ERROR
    end

    def pinned?
      !source_env_var.nil?
    end
  end
end
