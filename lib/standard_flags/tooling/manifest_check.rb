require "date"
require "json"

module StandardFlags
  module Tooling
    # `standard_flags:manifest:check`: fails server CI when the committed
    # manifest no longer describes the registry, or when the registry broke
    # the contract shipped clients were built against.
    #
    # * **stale**: the committed file differs from what
    #   `standard_flags:manifest` writes now, ignoring CRLF line endings and
    #   trailing newlines (or there is no committed file). Regenerating and
    #   committing fixes it.
    # * **removed wire**: a wire the baseline manifest tells an audience is
    #   gone from that audience, and no tombstone still serves it (`serve:`
    #   with `until:` today or later, in UTC). A shipped client reading it
    #   would silently fall back to its code default. A deprecated wire whose
    #   `until:` has passed in the baseline may go: its window is over.
    # * **type change**: a wire the baseline and the registry both tell an
    #   audience changed JSON type (boolean and string).
    # * **audience made private**: a public audience in the baseline that
    #   served wires is no longer public, so clients before sign-in lose
    #   every one of them.
    #
    # The baseline is `base:`: in CI, the base branch's manifest, so a PR
    # that regenerates the file in the same commit still can't drop a wire.
    # Without it (`base: :committed`) the committed file is the baseline, and
    # the result warns that a regenerated file hides removals. `base: nil` or
    # an Unavailable (a BASE file that is missing or unreadable) fails with
    # :baseline_unavailable, unless `base_optional: true` (first adoption: the
    # base branch has no manifest yet), which skips the contract checks with
    # a warning. Any manifest may be version 1.
    #
    # Shortening a deprecated wire's `until:` is a warning, not a break.
    #
    #   check = StandardFlags::Tooling::ManifestCheck.new(committed: File.read(path), base: base_json)
    #   result = check.call
    #   puts check.render(result)
    #   exit result.exit_code
    #
    # Exit codes: 0 ok; 1 stale or missing (regenerate); 2 a contract break,
    # an unavailable baseline or an unreadable manifest (regenerating won't
    # fix it, unless the unreadable one is the committed file).
    class ManifestCheck
      STATUSES = %i[ok missing stale breaking unreadable baseline_unavailable].freeze
      EXIT_CODES = { ok: 0, missing: 1, stale: 1, breaking: 2, unreadable: 2, baseline_unavailable: 2 }.freeze
      NO_BASE_WARNING = "no BASE was given: the removed-wire and type checks compared the registry with the committed " \
                        "file only, which a regenerated file passes; pass BASE= the base branch's manifest in CI".freeze

      # A baseline that couldn't be read, and why ("tmp/base.json does not
      # exist").
      Unavailable = Data.define(:reason)

      # One contract break. `kind` is :removed_wire, :type_changed or
      # :audience_made_private (`wire` nil).
      Finding = Data.define(:kind, :audience, :wire, :from, :to, :detail) do
        def to_h
          case kind
          when :removed_wire then { "audience" => audience, "wire" => wire }
          when :audience_made_private then { "audience" => audience }
          else { "audience" => audience, "wire" => wire, "from" => from, "to" => to }
          end
        end
      end

      Result = Data.define(:status, :stale, :changes, :removed_wires, :type_changes, :audiences_made_private,
                           :warnings, :error, :error_source) do
        def ok?
          status == :ok
        end

        def exit_code
          EXIT_CODES.fetch(status)
        end

        def findings
          removed_wires + type_changes + audiences_made_private
        end

        # Whether regenerating the committed file is (part of) the fix.
        def regenerate?
          case status
          when :missing, :stale then true
          when :breaking then stale
          when :unreadable then error_source == :committed
          else false
          end
        end
      end

      # A manifest that can't be read, and which one (:committed, :base or
      # :current).
      class SourceError < Error
        attr_reader :source

        def initialize(source, message)
          @source = source
          super(message)
        end
      end
      private_constant :SourceError

      # `committed` and `base` are a manifest's JSON text (as read from disk)
      # or a parsed Hash; `committed` is nil when there is no such file.
      # `current` is the registry's manifest as a Hash (Manifest#to_h);
      # `current_render` its text, compared with a committed String. `today`
      # is a UTC date.
      def initialize(committed:, base: :committed, base_optional: false, current: nil, current_render: nil,
                     today: Delivery.utc_today, registry: StandardFlags.registry)
        manifest = Manifest.new(registry: registry) if current.nil? || current_render.nil?
        @committed = committed
        @base = base
        @base_optional = base_optional
        @current = current || manifest.to_h
        @current_render = current_render || (current ? Manifest.format(current) : manifest.render)
        @today = today
      end

      def call
        warnings = []
        current = read(@current, :current)
        committed = @committed.nil? ? nil : read(@committed, :committed)
        base =
          case @base
          when :committed
            warnings << NO_BASE_WARNING
            committed
          when nil, Unavailable
            reason = @base.is_a?(Unavailable) ? @base.reason : "no baseline was given"
            return result(:baseline_unavailable, stale: false, error: reason) unless @base_optional

            warnings << "no baseline (#{reason}; BASE_OPTIONAL): the removed-wire and type checks were skipped"
            nil
          else read(@base, :base)
          end
        stale = committed.nil? || stale?
        removed, changed, privatised = base ? breaks(base, current) : [ [], [], [] ]
        warnings.concat(shortened_until(base, current)) if base
        result(status(removed + changed + privatised, committed, stale), stale: stale, changes: committed && stale ? self.class.changes(committed.data, current.data) : [],
                       removed_wires: removed, type_changes: changed, audiences_made_private: privatised, warnings: warnings)
      rescue SourceError => e
        result(:unreadable, stale: e.source == :committed, error: e.message, error_source: e.source)
      end

      # The report printed by the rake task. `path` names the committed file.
      def render(result, path: "the committed manifest")
        lines =
          case result.status
          when :ok then [ "standard_flags:manifest:check OK: #{path} matches the registry" ]
          when :unreadable then [ "standard_flags:manifest:check: can't read the #{result.error_source} manifest: #{result.error}" ]
          when :baseline_unavailable
            [ "standard_flags:manifest:check: the baseline manifest is unavailable (#{result.error}). The removed-wire and " \
              "type checks need it; set BASE_OPTIONAL=1 only when the base branch has no manifest yet." ]
          else []
          end
        lines.concat(result.warnings.map { |warning| "standard_flags:manifest:check: warning: #{warning}" })
        lines << "standard_flags:manifest:check: #{path} does not exist" if result.status == :missing || (result.status == :breaking && @committed.nil?)
        lines.concat(break_lines(result)) unless result.findings.empty?
        unless result.changes.empty?
          lines << "standard_flags:manifest:check: #{path} is stale:"
          lines.concat(result.changes.map { |change| "  #{change}" })
        end
        lines << "Run bin/rails standard_flags:manifest and commit the result." if result.regenerate?
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

      def status(findings, committed, stale)
        return :breaking unless findings.empty?
        return :missing if committed.nil?

        stale ? :stale : :ok
      end

      def read(value, source)
        Manifest.read(value)
      rescue Manifest::Unreadable => e
        raise SourceError.new(source, e.message)
      end

      # A committed String is compared as text with CRLF turned into LF and
      # trailing newlines folded into one, so a checkout with CRLF line
      # endings isn't permanently stale; a parsed Hash as a value.
      def stale?
        return normalize(@committed) != normalize(@current_render) if @committed.is_a?(String)

        @committed != @current
      end

      def normalize(text)
        text.b.gsub("\r\n", "\n").sub(/\n*\z/, "\n")
      end

      # Removed wires, type changes and audiences made private, from `base`
      # to `current`.
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
        [ removed, changed, privatised(base, current) ]
      end

      # Public audiences in `base` that served a wire today and aren't public
      # in `current` (one gone altogether shows up as removed wires).
      def privatised(base, current)
        base.audiences.select { |name, public| public && current.audiences[name] == false }.keys.sort.filter_map do |name|
          served = base.wires.fetch(name, {}).values.select { |wire| wire.served_on?(@today) }
          next if served.empty?

          Finding.new(kind: :audience_made_private, audience: name, wire: nil, from: nil, to: nil,
                      detail: "audience made private: #{name} was public, so clients before sign-in lose its " \
                              "#{served.size} wire#{'s' unless served.size == 1}; keep it public, or serve those wires elsewhere first")
        end
      end

      # Deprecated wires whose `until:` moved earlier than the baseline promised.
      def shortened_until(base, current)
        base.each_wire.filter_map do |wire|
          now = current.wire(wire.audience, wire.name)
          next unless wire.static? && wire.served_on?(@today) && now&.static? && now.until < wire.until

          "tombstone :#{now.key} now serves #{wire} through #{now.until.iso8601}, earlier than the " \
            "#{wire.until.iso8601} shipped clients were promised"
        end
      end

      def finding(kind, wire, detail:, from: nil, to: nil)
        Finding.new(kind: kind, audience: wire.audience, wire: wire.name, from: from, to: to, detail: detail)
      end

      def removed_detail(wire, now)
        if now
          "removed wire: #{wire} is served by tombstone :#{now.key} only through #{now.until.iso8601}, which has passed"
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

      def result(status, stale:, changes: [], removed_wires: [], type_changes: [], audiences_made_private: [], warnings: [],
                 error: nil, error_source: nil)
        Result.new(status: status, stale: stale, changes: changes, removed_wires: removed_wires, type_changes: type_changes,
                   audiences_made_private: audiences_made_private, warnings: warnings, error: error, error_source: error_source)
      end
    end
  end
end
