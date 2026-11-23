require "standard_health/check"

module StandardFlags
  # An opt-in standard_health check. Loaded on first reference, so apps
  # without standard_health never touch it.
  #
  #   StandardHealth.configure do |c|
  #     c.register_check :flags, StandardFlags::HealthCheck
  #   end
  #
  # * Fails when a `forbidden_in` flag is pinned on in this environment, or
  #   when runtime rules are on and their tables are missing.
  # * Warns on unparseable pins, legacy env names in use (deprecated), flags
  #   past remove_by, STANDARD_FLAGS_* variables that match no flag, a
  #   runtime-rule store that can't be reached, a stale runtime-rule
  #   snapshot, store warnings (such as prepared statements being off), and
  #   rules for undeclared or tombstoned keys.
  #
  # standard_health has no warning status, so warnings ride on the row as
  # `warnings:` and the check stays :ok. Pass `warn_as: :fail` to let them
  # degrade the tier instead. Non-critical by default: a bad pin is a reason
  # to look, not to pull an instance out of rotation.
  class HealthCheck < ::StandardHealth::Check
    VIOLATION_LABEL = "StandardFlags::ForbiddenPin".freeze
    RUNTIME_LABEL = "StandardFlags::RuntimeUnavailable".freeze
    WARNING_LABEL = "StandardFlags::FlagWarning".freeze

    attr_reader :warn_as

    def initialize(name: :standard_flags, critical: false, warn_as: :ok)
      super(name: name, critical: critical)
      raise ArgumentError, "warn_as: must be :ok or :fail" unless %i[ok fail].include?(warn_as)

      @warn_as = warn_as
    end

    def run
      report = nil
      timing = with_timing { report = Diagnostics.report }
      return timing unless timing[:status] == :ok

      forbidden = report[:forbidden_pins]
      unless forbidden.empty?
        names = forbidden.map { |p| "#{p[:flag]} (#{p[:env_var]})" }.join(", ")
        return timing.merge(status: :fail, error: "forbidden flags pinned on: #{names}", error_class: VIOLATION_LABEL)
      end
      if Diagnostics.runtime_unavailable?(report)
        return timing.merge(status: :fail, error: "runtime rules are on but their tables are missing; run the " \
                                                  "standard_flags:migrations generator and migrate",
                            error_class: RUNTIME_LABEL)
      end

      warnings = Diagnostics.warnings(report)
      return timing if warnings.empty?
      return timing.merge(warnings: warnings) if warn_as == :ok

      timing.merge(status: :fail, error: warnings.join("; "), error_class: WARNING_LABEL, warnings: warnings)
    end
  end
end
