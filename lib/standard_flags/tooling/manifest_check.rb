require "date"
require "json"

module StandardFlags
  module Tooling
    # `standard_flags:manifest:check`: fails server CI when the committed
    # manifest no longer describes the registry, or when the registry broke
    # the contract shipped clients were built against.
    #
    # * **stale**: the committed file's bytes differ from what
    #   `standard_flags:manifest` writes now (or there is no committed file).
    #   Regenerating and committing fixes it.
    # * **removed wire**: a wire the baseline manifest tells an audience is
    #   gone from that audience, and no tombstone still serves it (`serve:`
    #   with `until:` today or later, in UTC). A shipped client reading it
    #   would silently fall back to its code default. A deprecated wire whose
    #   `until:` has passed in the baseline may go: its window is over.
    # * **type change**: a wire the baseline and the registry both tell an
    #   audience changed JSON type (boolean and string).
    #
    # The baseline is `base:` when given (in CI, the base branch's manifest,
    # so a PR that regenerates the file in the same commit still can't drop
    # a wire), else the committed manifest. Either may be version 1.
    #
    #   check = StandardFlags::Tooling::ManifestCheck.new(committed: File.read(path), base: base_json)
    #   result = check.call
    #   puts check.render(result)
    #   exit result.exit_code
    #
    # Exit codes: 0 ok; 1 stale or missing (regenerate); 2 a removed wire, a
    # changed type or an unreadable manifest (regenerating won't fix it).
    class ManifestCheck
      STATUSES = %i[ok missing stale breaking unreadable].freeze
      EXIT_CODES = { ok: 0, missing: 1, stale: 1, breaking: 2, unreadable: 2 }.freeze

      # One contract break. `kind` is :removed_wire or :type_changed.
      Finding = Data.define(:kind, :audience, :wire, :from, :to, :detail) do
        def to_h
          case kind
          when :removed_wire then { "audience" => audience, "wire" => wire }
          else { "audience" => audience, "wire" => wire, "from" => from, "to" => to }
          end
        end
      end

      Result = Data.define(:status, :stale, :changes, :removed_wires, :type_changes, :error) do
        def ok?
          status == :ok
        end

        def exit_code
          EXIT_CODES.fetch(status)
        end

        def findings
          removed_wires + type_changes
        end
      end

      # `committed` and `base` are a manifest's JSON text (as read from disk)
      # or a parsed Hash; nil when there is no such file. `current` is the
      # registry's manifest as a Hash (Manifest#to_h); `current_render` its
      # bytes, compared with a committed String. `today` is a UTC date.
      def initialize(committed:, base: :committed, current: nil, current_render: nil, today: Delivery.utc_today,
                     registry: StandardFlags.registry)
        manifest = Manifest.new(registry: registry) if current.nil? || current_render.nil?
        @committed = committed
        @base = base == :committed ? committed : base
        @current = current || manifest.to_h
        @current_render = current_render || (current ? "#{JSON.pretty_generate(current)}\n" : manifest.render)
        @today = today
      end

      def call
        return result(:missing, stale: true, changes: [ "there is no committed manifest" ]) if @committed.nil?

        committed = Manifest.read(@committed)
        current = Manifest.read(@current)
        base = @base.equal?(@committed) ? committed : (@base && Manifest.read(@base))
        stale = stale?
        removed, changed = base ? breaks(base, current) : [ [], [] ]
        result(status(removed + changed, stale), stale: stale, changes: stale ? self.class.changes(committed.data, current.data) : [],
                       removed_wires: removed, type_changes: changed)
      rescue Manifest::Unreadable => e
        result(:unreadable, stale: true, error: e.message)
      end

      # The report printed by the rake task. `path` names the committed file.
      def render(result, path: "the committed manifest")
        lines =
          case result.status
          when :ok then [ "standard_flags:manifest:check OK: #{path} matches the registry" ]
          when :missing then [ "standard_flags:manifest:check: #{path} does not exist" ]
          when :unreadable then [ "standard_flags:manifest:check: can't read a manifest: #{result.error}" ]
          else []
          end
        lines.concat(break_lines(result)) unless result.findings.empty?
        if result.stale && result.status != :unreadable
          lines << "standard_flags:manifest:check: #{path} is stale:" unless result.status == :missing
          lines.concat(result.changes.map { |change| "  #{change}" }) unless result.status == :missing
        end
        lines << "Run bin/rails standard_flags:manifest and commit the result." if result.stale
        lines.join("\n")
      end

      # Human-readable differences between two manifest Hashes, one String
      # each: `+`/`-` for an added or removed flag, tombstone or top-level
      # entry, `~` with the fields that changed.
      def self.changes(old, new)
        lines = []
        same_version = old["version"] == new["version"]
        unless same_version
          lines << "~ version: #{old['version'].inspect} → #{new['version'].inspect} (regenerating upgrades the format)"
        end
        ((old.keys | new.keys) - %w[version flags tombstones]).sort.each do |field|
          lines.concat(field_changes(field, old[field], new[field]))
        end
        lines.concat(keyed_changes("flag", old["flags"], new["flags"], same_version))
        lines.concat(keyed_changes("tombstone", old["tombstones"], new["tombstones"], same_version))
        lines << "the content is identical but the bytes differ; regenerate instead of editing by hand" if lines.empty?
        lines
      end

      def self.field_changes(field, old, new)
        return [] if old == new
        return [ "+ #{field}" ] if old.nil?
        return [ "- #{field}" ] if new.nil?
        return [ "~ #{field}: #{json(old)} → #{json(new)}" ] unless old.is_a?(Hash) && new.is_a?(Hash)

        (old.keys | new.keys).sort.filter_map do |name|
          if !old.key?(name) then "+ #{field}.#{name}"
          elsif !new.key?(name) then "- #{field}.#{name}"
          elsif old[name] != new[name] then "~ #{field}.#{name}: #{json(old[name])} → #{json(new[name])}"
          end
        end
      end

      def self.keyed_changes(label, old, new, detail)
        old = Array(old).to_h { |entry| [ entry["key"], entry ] }
        new = Array(new).to_h { |entry| [ entry["key"], entry ] }
        (old.keys | new.keys).sort_by(&:to_s).filter_map do |key|
          if !old.key?(key) then "+ #{label} :#{key}"
          elsif !new.key?(key) then "- #{label} :#{key}"
          elsif old[key] != new[key]
            next "~ #{label} :#{key}" unless detail

            fields = (old[key].keys | new[key].keys).reject { |field| old[key][field] == new[key][field] }
            "~ #{label} :#{key}: " + fields.map { |field| "#{field} #{json(old[key][field])} → #{json(new[key][field])}" }.join("; ")
          end
        end
      end

      def self.json(value)
        value.nil? ? "(none)" : JSON.generate(value)
      end

      private

      def status(findings, stale)
        return :breaking unless findings.empty?

        stale ? :stale : :ok
      end

      def stale?
        return @committed != @current_render if @committed.is_a?(String)

        @committed != @current
      end

      # Removed wires and type changes from `base` to `current`.
      def breaks(base, current)
        removed = []
        changed = []
        base.each_wire do |wire|
          now = current.wire(wire.audience, wire.name)
          if now && now.type != wire.type
            changed << finding(:type_changed, wire, from: wire.type, to: now.type,
                                                    detail: "type changed: #{wire} was #{wire.type} and is now #{now.type}")
          end
          next unless wire.served_on?(@today)
          next if now&.served_on?(@today)

          removed << finding(:removed_wire, wire, detail: removed_detail(wire, now))
        end
        [ removed, changed ]
      end

      def finding(kind, wire, detail:, from: nil, to: nil)
        Finding.new(kind: kind, audience: wire.audience, wire: wire.name, from: from, to: to, detail: detail)
      end

      def removed_detail(wire, now)
        if now
          "removed wire: #{wire} is served by tombstone :#{now.key} only through #{now.until&.iso8601 || 'no date'}, which has passed"
        else
          what = wire.static? ? "tombstone :#{wire.key}, until #{wire.until.iso8601}" : "flag :#{wire.key}"
          "removed wire: #{wire} (#{what}) is gone and no tombstone serves it; keep it exposed, or add " \
            "serve: { #{wire.audience}: { #{wire.name}: <value> } }, until: \"YYYY-MM-DD\" to the tombstone"
        end
      end

      def break_lines(result)
        [ "standard_flags:manifest:check: the client contract is broken:" ] +
          result.findings.map { |finding| "  #{finding.detail}" }
      end

      def result(status, stale:, changes: [], removed_wires: [], type_changes: [], error: nil)
        Result.new(status: status, stale: stale, changes: changes, removed_wires: removed_wires,
                   type_changes: type_changes, error: error)
      end
    end
  end
end
