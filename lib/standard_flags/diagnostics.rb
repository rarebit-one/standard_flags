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
      rows = Runtime::CompatTracker.untracked do
        registry.definitions.map { |definition| row(registry, definition, env, environment, today) }
      end

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
      report[:clients] = clients(registry, env) unless registry.clients.empty?
      report[:compat] = compat(registry) if registry.definitions.any?(&:compat_window?)
      report.merge(status: status(report))
    end

    # The client registry with its ENV pins applied: the values in force
    # (versions as Strings, dates as YYYY-MM-DD), the pins that applied and
    # those ignored. Pins in force are listed here, as flags' pins are, and
    # never warn; only ignored ones do. `available` is the declared or
    # pinned one; a store lookup isn't asked here.
    def clients(registry, env)
      registry.clients.values.sort_by(&:name).map do |app|
        policy = app.resolve(env)
        { name: app.name, platform: app.platform, group: app.group, min_version: policy.min_version&.to_s,
          since: policy.since&.iso8601, enforce_on: policy.enforce_on&.iso8601, grace_days: app.grace_days,
          recommended: policy.recommended&.to_s, available: policy.available&.to_s, store_url: app.store_url,
          store_lookup: app.store_lookup?, pinned: policy.pinned, rejected: policy.rejected }
      end
    end

    # Compat flags with `until_clients:`, and their stored counts when
    # `config.track_compat` is on (`stats` is nil when off, or when the
    # store keeps none; `error` names the error class when it can't be read).
    def compat(registry)
      windows = registry.definitions.select(&:compat_window?).sort_by(&:key)
      tracking = StandardFlags.config.track_compat == true && Runtime.enabled?
      stats, error = compat_stats(windows) if tracking
      grouped = (stats || []).group_by { |stat| stat.key.to_s }
      { tracking: tracking, error: error, flags: windows.map do |definition|
        markers, rows = grouped.fetch(definition.key.to_s, []).partition(&:marker?)
        { flag: definition.key, until_clients: definition.until_clients.transform_values(&:to_s),
          tracking_since: markers.first&.first_seen_at&.utc&.iso8601,
          last_flushed_at: markers.first&.last_flushed_at&.utc&.iso8601, stats: stats && rows.map(&:to_h) }
      end }
    end

    def compat_stats(windows)
      [ Runtime.compat_stats(windows.map(&:key)), nil ]
    rescue StandardError => e
      [ nil, (e.cause_class if e.is_a?(Runtime::StoreError)) || e.class.name ]
    end

    # One line per warning, names only.
    def warnings(report)
      report[:rejected_pins].map { |p| "#{p[:env_var]} for :#{p[:flag]} is not a valid value (ignored)" } +
        report[:legacy_env_vars].map { |p| "#{p[:env_var]} for :#{p[:flag]} is deprecated; rename to #{p[:canonical]}" } +
        report[:stale].map { |s| ":#{s[:flag]} is past remove_by #{s[:remove_by]}" } +
        report[:unknown_env_vars].map { |var| "#{var} does not match a declared flag" } +
        runtime_warnings(report[:runtime]) + client_warnings(report[:clients]) + compat_warnings(report[:compat])
    end

    # Only ignored pins warn: a valid break-glass pin is listed under
    # `clients:`, never turned into a health warning.
    def client_warnings(clients)
      Array(clients).flat_map do |client|
        client[:rejected].map { |var| "#{var} for client :#{client[:name]} was ignored (invalid, or a raised minimum without _SINCE)" }
      end
    end

    def compat_warnings(compat)
      return [] if compat.nil?
      return [ "compat stats could not be read (#{compat[:error]})" ] if compat[:error]
      return [] unless StandardFlags.config.track_compat == true && !compat[:tracking]

      [ "config.track_compat is on but runtime rules are off, so compat hits are not counted" ]
    end

    # Runtime rules are on but the store says their tables are missing. A
    # store that can't be reached is a warning instead: flags keep serving
    # the last good snapshot (or code defaults) through a database blip.
    def runtime_unavailable?(report)
      tables_missing?(report[:runtime])
    end

    def tables_missing?(runtime)
      !runtime.nil? && !runtime[:ready] && runtime[:unreachable].nil?
    end

    def runtime_warnings(runtime)
      return [] if runtime.nil? || tables_missing?(runtime)

      warnings = []
      if runtime[:unreachable]
        warnings << "runtime rules store is unreachable (#{runtime[:unreachable]}); flags keep serving the last good snapshot"
      end
      if runtime[:stale]
        serving = runtime[:loaded] ? "revision #{runtime[:revision]}, #{runtime[:age]}s old" : "code defaults"
        warnings << "runtime rules are stale: the last refresh failed (serving #{serving})"
      end
      warnings.concat(runtime[:warnings])
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

      declared = registry.keys.map { |key| "#{CANONICAL_PREFIX}#{key.to_s.upcase}" } +
                 registry.clients.each_value.flat_map(&:env_vars)
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
