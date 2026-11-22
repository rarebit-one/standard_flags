require "date"
require "json"
require "pathname"
require "active_support/core_ext/string/inflections"

module StandardFlags
  # The logic behind the rake tasks, kept out of the rake file so it can be
  # tested without booting an app.
  module Tooling
    # `flags:list`: every flag, its value here, and where the value came from.
    # A permanent flag shows `permanent` in the remove_by column.
    class List
      HEADERS = %w[key kind value reason env_var remove_by].freeze

      def initialize(registry: StandardFlags.registry)
        @registry = registry
      end

      def rows
        @registry.definitions.sort_by(&:key).map do |definition|
          evaluation = Evaluator.evaluate(@registry, definition.key, Context.empty)
          [ definition.key.to_s, definition.kind.to_s, evaluation.value.to_s, evaluation.reason,
            evaluation.source_env_var || "-", lifecycle(definition) ]
        end
      end

      def render
        table = [ HEADERS ] + rows
        widths = HEADERS.each_index.map { |i| table.map { |row| row[i].length }.max }
        table.map { |row| row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }.join("\n")
      end

      private

      def lifecycle(definition)
        return "permanent" if definition.permanent?

        definition.remove_by&.iso8601 || "-"
      end
    end

    # `flags:stale`: flags past their remove_by date. Each one's `final:`
    # value says which branch to keep when deleting it. Permanent flags have
    # no remove_by date, so they never appear.
    class Stale
      def initialize(registry: StandardFlags.registry, today: Date.today)
        @registry = registry
        @today = today
      end

      def definitions
        @registry.definitions.select { |definition| definition.stale?(@today) }.sort_by(&:remove_by)
      end

      def render
        stale = definitions
        return "No flags are past their remove_by date." if stale.empty?

        stale.map do |definition|
          final = definition.final.nil? ? "" : ", final: #{definition.final.inspect}"
          "#{definition.key} (#{definition.kind}, owner: #{definition.owner}) " \
            "was due for removal on #{definition.remove_by.iso8601}#{final}"
        end.join("\n")
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
    # Entries of kind `flag` also say whether the flag is permanent.
    class Manifest
      VERSION = 1

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
        entry["permanent"] = definition.permanent? if definition.kind == :flag
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
    # audience, keyed by wire name.
    class TypeScript
      IDENTIFIER = /\A[A-Za-z_$][A-Za-z0-9_$]*\z/

      def initialize(registry: StandardFlags.registry)
        @registry = registry
      end

      def render
        audiences = @registry.audiences
        out = [ "// Generated by `bin/rails standard_flags:typescript`. Do not edit by hand.", "" ]
        audiences.each do |audience|
          out << "export interface #{interface_name(audience)} {"
          @registry.exposed(audience).each do |definition|
            out << "  readonly #{property(definition.wire_name(audience))}: #{type(definition)};"
          end
          out << "}" << ""
        end
        out << "export type FeaturesByAudience = {"
        audiences.each { |audience| out << "  #{property(audience.to_s)}: #{interface_name(audience)};" }
        out << "};" << ""
        out.join("\n")
      end

      private

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
