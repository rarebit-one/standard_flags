require "date"
require "json"
require "pathname"
require "active_support/core_ext/string/inflections"
require "standard_flags/tooling/changes"

module StandardFlags
  # The logic behind the rake tasks, kept out of the rake file so it can be
  # tested without booting an app.
  module Tooling
    # `flags:list`: every flag, its value here, and where the value came from.
    # A permanent flag shows `permanent` in the remove_by column. With
    # runtime rules on, a `rule` column shows each flag's rule status, and a
    # header line the snapshot's revision and age.
    class List
      HEADERS = %w[key kind value reason env_var remove_by].freeze
      RUNTIME_HEADERS = (HEADERS + %w[rule]).freeze

      def initialize(registry: StandardFlags.registry)
        @registry = registry
      end

      def headers
        Runtime.enabled? ? RUNTIME_HEADERS : HEADERS
      end

      def rows
        runtime = Runtime.enabled?
        @registry.definitions.sort_by(&:key).map do |definition|
          evaluation = Evaluator.evaluate(@registry, definition.key, Context.empty)
          row = [ definition.key.to_s, definition.kind.to_s, evaluation.value.to_s, evaluation.reason,
                  evaluation.source_env_var || "-", lifecycle(definition) ]
          runtime ? row << (Runtime.snapshot.rule(definition.key)&.status || "-") : row
        end
      end

      def render
        table = [ headers ] + rows
        widths = headers.each_index.map { |i| table.map { |row| row[i].length }.max }
        lines = table.map { |row| row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
        ([ runtime_line ].compact + lines).join("\n")
      end

      private

      def lifecycle(definition)
        return "permanent" if definition.permanent?

        definition.remove_by&.iso8601 || "-"
      end

      def runtime_line
        return unless Runtime.enabled?

        snapshot = Runtime.snapshot
        return "runtime rules: not loaded (serving code defaults)" unless snapshot.loaded

        orphans = snapshot.rules.keys.reject { |key| @registry.key?(key) }
        line = "runtime rules: revision #{snapshot.revision}, #{snapshot.age}s old#{', stale' if snapshot.stale}"
        orphans.empty? ? line : "#{line}; rules for undeclared keys: #{orphans.sort.join(', ')}"
      end
    end

    # `flags:stale`: flags and modes past their remove_by date. Each one's
    # `final:` value says which branch to keep when deleting it. Permanent
    # flags have no remove_by date, so they never appear. Tombstones whose
    # `serve:` block is past its `until:` date are listed too: their static
    # wires are no longer served, so the block can be deleted.
    #
    # With runtime rules on it also lists rules worth cleaning up: at 100%
    # or stopped for 30 days or more, not evaluated in 14 days (when
    # `config.track_evaluations` is on), and rules for undeclared or
    # tombstoned keys; and memberships past `config.membership_retention`
    # that `flags:purge` would delete.
    #
    # With `config.track_compat` on, it says a compat window "can be
    # removed" only when tracking has run for at least 14 days (the flag's
    # tracking marker), a write has succeeded in the last 2 days (the
    # marker's last flush, so missing hits really mean no use), no hit has
    # landed in the last 14 days, and the window has passed on every
    # platform `until_clients:` names. A platform's window has passed when
    # every client declared for it enforces a minimum at or above the listed
    # version today (UTC), or when no client below that version has used
    # the flag (no hits from the platform, or its oldest version seen is at
    # or above it). Until tracking is old enough it says "not enough data";
    # when writes have stopped succeeding, "tracking unhealthy since …".
    class Stale
      SETTLED_AFTER = 30 * 86_400
      UNUSED_AFTER = 14 * 86_400

      def initialize(registry: StandardFlags.registry, today: Date.today, now: Time.now.utc, store: nil)
        @registry = registry
        @today = today
        @now = now
        @store = store
      end

      def definitions
        @registry.definitions.select { |definition| definition.stale?(@today) }.sort_by(&:remove_by)
      end

      # Tombstones whose static wires stopped being served after `until:`.
      def expired_serves
        @registry.tombstones.values.select { |tombstone| tombstone.serve_expired?(@today) }.sort_by(&:key)
      end

      def render
        stale = definitions
        lines =
          if stale.empty?
            [ "No flags are past their remove_by date." ]
          else
            stale.map do |definition|
              final = definition.final.nil? ? "" : ", final: #{definition.final.inspect}"
              "#{definition.key} (#{definition.kind}, owner: #{definition.owner}) " \
                "was due for removal on #{definition.remove_by.iso8601}#{final}"
            end
          end
        lines.concat(serve_lines)
        lines.concat(compat_lines)
        lines.concat(runtime_lines) if Runtime.enabled?
        lines.join("\n")
      end

      # Findings about stored rules and memberships, one String each.
      def runtime_findings
        loaded = store.load
        findings = loaded.rules.sort_by(&:key).flat_map { |rule| rule_findings(rule) }
        due = store.purgeable(before: @now - StandardFlags.config.membership_retention)
        unless (due[:removed] + due[:expired]).zero?
          findings << "#{due[:removed]} removed and #{due[:expired]} expired memberships are past retention; run flags:purge"
        end
        findings
      end

      private

      def store
        @store || Runtime.store
      end

      def serve_lines
        expired_serves.map do |tombstone|
          wires = tombstone.serve.flat_map { |audience, statics| statics.keys.map { |wire| "#{audience}.#{wire}" } }
          "tombstone #{tombstone.key} stopped serving #{wires.sort.join(', ')} after #{tombstone.serve_until.iso8601}; " \
            "its serve: block can be removed"
        end
      end

      def compat_lines
        windows = @registry.definitions.select(&:compat_window?).sort_by(&:key)
        return [] if windows.empty? || !StandardFlags.config.track_compat || !Runtime.enabled?

        stats = store.compat_stats(windows.map { |definition| definition.key.to_s })
        return [ "compat windows: the runtime store doesn't keep compat stats" ] if stats.nil?

        by_key = stats.group_by { |stat| stat.key.to_s }
        windows.filter_map { |definition| compat_finding(definition, by_key.fetch(definition.key.to_s, [])) }
      rescue StandardError => e
        [ "compat windows: could not read the stats (#{(e.cause_class if e.is_a?(Runtime::StoreError)) || e.class})" ]
      end

      def compat_finding(definition, stats)
        marker, stats = stats.partition(&:marker?)
        since = marker.first&.first_seen_at
        if since.nil? || since > @now - Runtime::CompatTracker::IDLE
          tracking = since ? "tracking since #{day(since)}" : "no tracking recorded yet"
          return "compat #{definition.key}: not enough data to judge its window (#{tracking}; needs 14 days)"
        end
        flushed = marker.first.last_flushed_at
        if flushed.nil? || flushed < @now - Runtime::CompatTracker::HEALTHY
          return "compat #{definition.key}: tracking unhealthy since #{day(flushed || since)} (no successful write since); " \
                 "not enough data to judge its window"
        end

        last = stats.filter_map(&:last_hit_at).max
        return if last && last > @now - Runtime::CompatTracker::IDLE
        return unless definition.until_clients.all? { |platform, cutoff| window_passed?(platform, cutoff, stats) }

        windows = definition.until_clients.map { |platform, cutoff| "#{platform} #{cutoff}" }.join(", ")
        seen = last ? "no hits since #{day(last)}" : "no hits since tracking began on #{day(since)}"
        "compat #{definition.key} (owner: #{definition.owner}) is past its window on every platform (#{windows}) " \
          "and has had #{seen}; it can be removed"
      end

      def window_passed?(platform, cutoff, stats)
        apps = @registry.clients.each_value.select { |app| app.platform == platform }
        return true if !apps.empty? && apps.all? { |app| enforced_at_least?(app, cutoff) }

        stat = stats.find { |entry| entry.platform == platform }
        return true if stat.nil?

        oldest = Version.parse(stat.oldest_version)
        !oldest.nil? && oldest >= cutoff
      end

      def enforced_at_least?(app, cutoff)
        policy = app.resolve
        return false if policy.min_version.nil? || @now.utc.to_date < policy.enforce_on

        ceiling = policy.ceiling
        minimum = ceiling ? [ policy.min_version, ceiling ].min : policy.min_version
        minimum >= cutoff
      end

      def runtime_lines
        findings = runtime_findings
        findings.empty? ? [ "No stale runtime rules." ] : findings
      rescue StandardError => e
        [ "runtime rules: could not read the store (#{(e.cause_class if e.is_a?(Runtime::StoreError)) || e.class})" ]
      end

      def rule_findings(rule)
        findings = []
        if @registry.tombstoned?(rule.key)
          findings << "rule :#{rule.key} is for a tombstoned flag"
        elsif !@registry.key?(rule.key)
          findings << "rule :#{rule.key} is for an undeclared flag"
        end
        if rule.percentage_bps == Bucket::BUCKETS && rule.full_since && rule.full_since <= @now - SETTLED_AFTER
          findings << "rule :#{rule.key} has served 100% since #{day(rule.full_since)}; remove the flag or Stop it"
        end
        if rule.stopped? && rule.updated_at && rule.updated_at <= @now - SETTLED_AFTER
          findings << "rule :#{rule.key} has been stopped since #{day(rule.updated_at)}; remove the flag"
        end
        last = rule.last_evaluated_at || rule.updated_at
        if StandardFlags.config.track_evaluations && last && last <= @now - UNUSED_AFTER
          seen = rule.last_evaluated_at ? "since #{day(last)}" : "since it changed on #{day(last)}"
          findings << "rule :#{rule.key} has not been evaluated #{seen}"
        end
        findings
      end

      def day(time)
        time.utc.to_date.iso8601
      end
    end

    # `flags:refs`: fails on keys read in code but not declared (including
    # tombstoned ones), and warns on declared flags nothing reads.
    class Refs
      CALL = /\b(?:on\?|off\?|mode|variant|evaluate|peek|sensor|enabled\?)\(\s*[:"']([a-z][a-z0-9_]*)/
      GUARD = /\brequires_flag[\s(]+[:"']([a-z][a-z0-9_]*)/
      PATTERNS = [ CALL, GUARD ].freeze

      Result = Data.define(:references, :undeclared, :unreferenced) do
        def failed?
          !undeclared.empty?
        end
      end

      def initialize(registry: StandardFlags.registry, root: Dir.pwd, paths: nil, extensions: nil, exclude: nil)
        config = StandardFlags.config
        @registry = registry
        @root = Pathname(root)
        @paths = paths || config.refs_paths
        @extensions = extensions || config.refs_extensions
        @exclude = Array(exclude || config.registry_path).map { |path| @root.join(path).expand_path.to_s }
      end

      def call
        references = Hash.new { |hash, key| hash[key] = [] }
        files.each do |file|
          File.foreach(file).with_index(1) do |line, number|
            PATTERNS.each do |pattern|
              line.scan(pattern) { |(key)| references[key.to_sym] << "#{relative(file)}:#{number}" }
            end
          end
        end

        Result.new(
          references: references.to_h,
          undeclared: references.keys.reject { |key| @registry.key?(key) }.sort.to_h { |key| [ key, references[key] ] },
          unreferenced: (@registry.keys - references.keys).sort
        )
      end

      def render(result)
        lines = result.undeclared.map do |key, locations|
          label = @registry.tombstoned?(key) ? "tombstoned" : "undeclared"
          "ERROR #{label} flag :#{key} used at #{locations.join(', ')}"
        end
        lines += result.unreferenced.map { |key| "WARN  declared flag :#{key} has no references" }
        lines << "flags:refs OK (#{result.references.size} keys referenced)" if lines.empty?
        lines.join("\n")
      end

      private

      def files
        glob = "**/*.{#{@extensions.join(',')}}"
        @paths.flat_map { |path| Dir.glob(@root.join(path, glob).to_s) }
              .map { |file| File.expand_path(file) }
              .uniq.sort - @exclude
      end

      def relative(file)
        Pathname(file).relative_path_from(@root.expand_path).to_s
      end
    end

    # `standard_flags:manifest`: a deterministic description of the flag set
    # (keys, wire names, kinds, values, audiences, defaults) for client CI.
    # Entries of kind `flag` and `mode` also say whether they are permanent.
    # `audiences` maps each audience to its first wire name, as in version 1;
    # a flag with aliases also lists every wire name per audience under
    # `wires`, so a version 1 reader still reads it.
    class Manifest
      VERSION = 1
      LIFECYCLE_KINDS = %i[flag mode].freeze

      def initialize(registry: StandardFlags.registry)
        @registry = registry
      end

      def to_h
        {
          "version" => VERSION,
          "flags" => @registry.definitions.sort_by(&:key).map { |definition| flag(definition) },
          "tombstones" => @registry.tombstones.values.sort_by(&:key).map do |tombstone|
            { "key" => tombstone.key.to_s, "removed" => tombstone.removed.iso8601 }
          end
        }
      end

      def render
        "#{JSON.pretty_generate(to_h)}\n"
      end

      private

      def flag(definition)
        entry = {
          "key" => definition.key.to_s,
          "kind" => definition.kind.to_s,
          "type" => definition.boolean? ? "boolean" : "string",
          "values" => definition.allowed_values.map { |value| wire(value) },
          "default" => default(definition),
          "audiences" => definition.expose.sort.to_h { |audience, name| [ audience.to_s, name ] }
        }
        if definition.exposure.any? { |_, wires| wires.size > 1 }
          entry["wires"] = definition.exposure.sort.to_h { |audience, wires| [ audience.to_s, wires ] }
        end
        entry["permanent"] = definition.permanent? if LIFECYCLE_KINDS.include?(definition.kind)
        entry
      end

      def default(definition)
        declared = definition.declared_default
        return wire(definition.kind_default) if declared.nil?
        return wire(declared) unless declared.is_a?(Hash)

        { "*" => wire(definition.kind_default) }.merge(declared.sort.to_h { |env, value| [ env, wire(value) ] })
      end

      def wire(value)
        value.is_a?(Symbol) ? value.to_s : value
      end
    end

    # `standard_flags:typescript`: a `.d.ts` with one Features interface per
    # audience, keyed by wire name; every flag key and its stored values; and
    # the shapes of StandardFlags::MCP's results, which the admin pages
    # (`standard_flags:admin`) are typed from.
    class TypeScript
      IDENTIFIER = /\A[A-Za-z_$][A-Za-z0-9_$]*\z/

      # The JSON StandardFlags::MCP returns (and the admin controller passes
      # as props). Static: the flag-specific parts are FlagKey and FlagValues.
      MCP_TYPES = <<~TS.freeze
        // Results of StandardFlags::MCP tools: the admin page props.
        export type FlagKind = "flag" | "kill_switch" | "mode" | "experiment" | "compat";
        export type RuleStatus = "draft" | "running" | "paused" | "stopped";

        export interface FlagPin {
          readonly env_var: string;
          readonly label: string;
        }

        export interface FlagRuleSummary {
          readonly status: RuleStatus;
          readonly revision: number;
          readonly percentage_bps: number | null;
          readonly member_count: number;
        }

        export interface FlagRule {
          readonly status: RuleStatus;
          readonly revision: number;
          readonly hash_version: number;
          readonly percentage_bps: number | null;
          readonly rollout_value: string | null;
          readonly variant_weights: Readonly<Record<string, number>>;
          readonly fallthrough_value: string | null;
          readonly stop_value: string | null;
          readonly conditions: Readonly<Record<string, unknown>>;
          readonly cohorts: ReadonlyArray<{ readonly cohort: string; readonly value: string }>;
          readonly hidden_cohorts: number;
          readonly member_count: number;
          readonly full_since: string | null;
          readonly last_evaluated_at: string | null;
        }

        export interface FlagSummary {
          readonly key: FlagKey;
          readonly kind: FlagKind;
          readonly owner: string | null;
          readonly description: string | null;
          readonly unit: string | null;
          readonly values: ReadonlyArray<string>;
          readonly value: string | null;
          readonly reason: string;
          readonly source: string;
          readonly pinned: FlagPin | null;
          readonly rule: FlagRuleSummary | null;
        }

        export interface FlagList {
          readonly flags: ReadonlyArray<FlagSummary>;
          readonly runtime_rules: boolean;
          readonly store_revision: number | null;
        }

        export interface FlagEvaluation {
          readonly unit_key: string | null;
          readonly value: string | null;
          readonly variant: string | null;
          readonly reason: string;
          readonly error_code: string | null;
          readonly rule_id: string | null;
          readonly source: string;
        }

        export interface FlagDetail {
          readonly key: FlagKey;
          readonly kind: FlagKind;
          readonly owner: string | null;
          readonly description: string | null;
          readonly unit: string | null;
          readonly values: ReadonlyArray<string>;
          readonly default: string | null;
          readonly evaluation: FlagEvaluation;
          readonly pinned: FlagPin | null;
          readonly runtime_rules: boolean;
          readonly rule: FlagRule | null;
          readonly store_revision: number | null;
        }

        export interface FlagMember {
          readonly unit: string;
          readonly unit_key: string;
          readonly value: string;
          readonly expires_at: string | null;
          readonly expired: boolean;
          readonly added_at: string | null;
        }

        export interface FlagMemberPage {
          readonly total: number;
          readonly offset: number;
          readonly limit: number;
          readonly next_offset: number | null;
          readonly revealed: boolean;
          readonly members: ReadonlyArray<FlagMember>;
        }

        export interface FlagAuditEntry {
          readonly event: string;
          readonly occurred_at: string | null;
          readonly actor: string | null;
          readonly reason: string | null;
          readonly revision: number | null;
        }
      TS

      def initialize(registry: StandardFlags.registry)
        @registry = registry
      end

      def render
        audiences = @registry.audiences
        out = [ "// Generated by `bin/rails standard_flags:typescript`. Do not edit by hand.", "" ]
        audiences.each do |audience|
          out << "export interface #{interface_name(audience)} {"
          @registry.wires(audience).each do |wire, definition|
            out << "  readonly #{property(wire)}: #{type(definition)};"
          end
          out << "}" << ""
        end
        out << "export type FeaturesByAudience = {"
        audiences.each { |audience| out << "  #{property(audience.to_s)}: #{interface_name(audience)};" }
        out << "};" << ""
        out.concat(flag_types)
        out << MCP_TYPES
        out.join("\n")
      end

      private

      # FlagKey (every declared key) and FlagValues (each flag's stored
      # values: "on"/"off", mode values, variants).
      def flag_types
        definitions = @registry.definitions.sort_by(&:key)
        keys = definitions.map { |definition| definition.key.to_s.to_json }
        out = [ "export type FlagKey = #{keys.empty? ? 'never' : keys.join(' | ')};", "", "export type FlagValues = {" ]
        definitions.each do |definition|
          values = definition.allowed_values.map { |value| Runtime.wire(value).to_json }.join(" | ")
          out << "  readonly #{property(definition.key.to_s)}: #{values};"
        end
        out << "};" << ""
      end

      def interface_name(audience)
        "#{audience.to_s.camelize}Features"
      end

      def property(name)
        name.match?(IDENTIFIER) ? name : name.to_json
      end

      def type(definition)
        return "boolean" if definition.boolean?

        definition.allowed_values.map { |value| value.to_s.to_json }.join(" | ")
      end
    end
  end
end
