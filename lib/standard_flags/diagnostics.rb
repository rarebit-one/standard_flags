require "date"
require "time"

module StandardFlags
  # What the running process thinks, for a diagnostics page or the health
  # check: every flag's value and where it came from, plus the pins that need
  # attention. Variable NAMES only; raw environment values never appear.
  module Diagnostics
    CANONICAL_PREFIX = "STANDARD_FLAGS_".freeze

    module_function

    def report(registry: StandardFlags.registry, env: StandardFlags.config.env_source, today: Date.today)
      environment = safe_env(registry)
      rows = registry.definitions.map { |definition| row(registry, definition, env, environment, today) }

      report = {
        environment: environment,
        generated_at: Time.now.utc.iso8601,
        flags: rows.map { |r| r.except(:scan, :forbidden_pin) },
        forbidden_pins: forbidden_pins(rows, environment),
        rejected_pins: rows.flat_map { |r| r[:scan].rejected.map { |var| { flag: r[:key], env_var: var } } },
        legacy_env_vars: legacy_env_vars(rows),
        stale: rows.select { |r| r[:stale] }.map { |r| { flag: r[:key], remove_by: r[:remove_by] } },
        unknown_env_vars: unknown_env_vars(registry, env)
      }
      report[:runtime] = Runtime.status(registry: registry) if Runtime.enabled?
      report.merge(status: status(report))
    end

    # One line per warning, names only.
    def warnings(report)
      report[:rejected_pins].map { |p| "#{p[:env_var]} for :#{p[:flag]} is not a valid value (ignored)" } +
        report[:legacy_env_vars].map { |p| "#{p[:env_var]} for :#{p[:flag]} is deprecated; rename to #{p[:canonical]}" } +
        report[:stale].map { |s| ":#{s[:flag]} is past remove_by #{s[:remove_by]}" } +
        report[:unknown_env_vars].map { |var| "#{var} does not match a declared flag" } +
        runtime_warnings(report[:runtime])
    end

    # Runtime rules are on but their tables (or store) aren't there.
    def runtime_unavailable?(report)
      runtime = report[:runtime]
      !runtime.nil? && !runtime[:ready]
    end

    def runtime_warnings(runtime)
      return [] if runtime.nil? || !runtime[:ready]

      warnings = []
      if runtime[:stale]
        serving = runtime[:loaded] ? "revision #{runtime[:revision]}, #{runtime[:age]}s old" : "code defaults"
        warnings << "runtime rules are stale: the last refresh failed (serving #{serving})"
      end
      warnings + runtime[:rules].select { |rule| rule[:orphan] }.map do |rule|
        "runtime rule for :#{rule[:key]} has no declared flag (#{rule[:orphan]})"
      end
    end

    def row(registry, definition, env, environment, today)
      evaluation = Evaluator.evaluate(registry, definition.key, Context.new(env: environment))
      scan = EnvPin.scan(definition, env)
      row = {
        key: definition.key,
        kind: definition.kind,
        owner: definition.owner,
        value: evaluation.value,
        reason: evaluation.reason,
        source_env_var: evaluation.source_env_var,
        pinned: !scan.pin.nil?,
        remove_by: definition.remove_by&.iso8601,
        permanent: definition.permanent?,
        stale: definition.stale?(today),
        audiences: definition.expose.transform_keys(&:to_s),
        scan: scan,
        forbidden_pin: forbidden_pin(definition, scan, environment)
      }
      row[:rule_status] = Runtime.snapshot.rule(definition.key)&.status if Runtime.enabled?
      row
    end

    # The variable pinning a `forbidden_in` flag on here, if any.
    def forbidden_pin(definition, scan, environment)
      return unless environment && definition.forbidden_in?(environment)
      return unless scan.pin && scan.pin.value != definition.off_value

      scan.pin.var
    end

    def forbidden_pins(rows, environment)
      rows.filter_map do |r|
        { flag: r[:key], env_var: r[:forbidden_pin], environment: environment } if r[:forbidden_pin]
      end
    end

    def legacy_env_vars(rows)
      rows.flat_map do |r|
        r[:scan].legacy.map do |var|
          { flag: r[:key], env_var: var, canonical: "#{CANONICAL_PREFIX}#{r[:key].to_s.upcase}",
            shadowed: r[:scan].shadowed_legacy.include?(var) }
        end
      end
    end

    def unknown_env_vars(registry, env)
      return [] unless env.respond_to?(:keys)

      declared = registry.keys.map { |key| "#{CANONICAL_PREFIX}#{key.to_s.upcase}" }
      env.keys.select { |name| name.to_s.start_with?(CANONICAL_PREFIX) }.map(&:to_s).reject { |n| declared.include?(n) }.sort
    end

    def status(report)
      return :fail if report[:forbidden_pins].any? || runtime_unavailable?(report)
      return :warn if warnings(report).any?

      :ok
    end

    def safe_env(registry)
      registry.current_env
    rescue StandardError
      nil
    end
  end
end
