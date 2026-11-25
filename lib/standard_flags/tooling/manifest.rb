require "date"
require "digest"
require "json"

module StandardFlags
  module Tooling
    # `standard_flags:manifest`: a deterministic description of the flag set
    # for client CI, committed as `config.manifest_path`. Version 2:
    #
    #   {
    #     "version": 2,
    #     "audiences": { "mobile": { "public": false } },
    #     "flags": [
    #       { "key": "ai_assistant", "kind": "kill_switch", "type": "boolean",
    #         "values": [true, false], "default": true,
    #         "audiences": { "mobile": ["chat", "chatEnabled"] }, "min_client": {} },
    #       { "key": "new_checkout", "kind": "flag", ..., "min_client": { "android": "0.4.0" },
    #         "permanent": false, "remove_by": "2027-03-01", "final": true }
    #     ],
    #     "tombstones": [
    #       { "key": "chat_v1", "removed": "2026-12-01", "serve": { "mobile": { "chat_v1": false } },
    #         "until": "2027-03-01", "until_clients": { "android": "0.6.0" } }
    #     ]
    #   }
    #
    # * `audiences` (top level) lists every audience a flag or tombstone
    #   serves, plus those `config.audiences` declares, and whether each is
    #   served before sign-in.
    # * A flag's `audiences` maps each audience to every wire name it sees,
    #   in declared order. `min_client` is always present (`{}` without one).
    # * `permanent` is on entries of kind `flag` and `mode`; `remove_by` and
    #   `final` only when declared.
    # * A tombstone has `serve`, `until` and `until_clients` (`{}` when not
    #   given) only when it still declares deprecated wires.
    #
    # `owner:` and `description:` are left out on purpose: the manifest is the
    # contract client repositories copy, and it holds nothing but what a
    # client may already learn from the wire plus lifecycle dates. Operators
    # read owners through `flags:list`, `flags:show` and the MCP tools.
    #
    # Version 1 manifests (0.3.0 and earlier) are still read (`.read`), so
    # `standard_flags:manifest:check` can compare an old committed file with
    # the registry and report what upgrading changes.
    class Manifest
      VERSION = 2
      READABLE_VERSIONS = [ 1, 2 ].freeze
      LIFECYCLE_KINDS = %i[flag mode].freeze
      TYPES = %w[boolean string].freeze

      # A manifest that can't be read: not JSON, not an object, an unknown
      # version or a malformed entry.
      class Unreadable < Error; end

      # One wire a manifest says an audience is told: its JSON type, and
      # where it comes from (`:flag`, or `:static` for a tombstone's
      # deprecated wire, served through `until`).
      Wire = Data.define(:audience, :name, :type, :source, :key, :until) do
        def to_s
          "#{audience}.#{name}"
        end

        def static?
          source == :static
        end

        # Whether a static wire is still served on `today` (a UTC date).
        # Flag wires always are.
        def served_on?(today)
          !static? || (!self.until.nil? && today <= self.until)
        end
      end

      # A parsed manifest of either version: the document as given and the
      # wires it declares, `{ audience => { wire => Wire } }`.
      class Document
        attr_reader :version, :data, :wires

        def initialize(data)
          @data = data
          @version = data["version"]
          @wires = Manifest.wires_in(data)
          freeze
        end

        def wire(audience, name)
          wires.dig(audience, name)
        end

        def each_wire(&)
          wires.values.flat_map(&:values).sort_by { |wire| [ wire.audience, wire.name ] }.each(&)
        end
      end

      # A Document from a JSON String or an already-parsed Hash. Raises
      # Unreadable.
      def self.read(source)
        data = source.is_a?(String) ? JSON.parse(source) : source
        raise Unreadable, "the manifest is not a JSON object" unless data.is_a?(Hash)

        version = data["version"]
        unless READABLE_VERSIONS.include?(version)
          raise Unreadable, "unknown manifest version #{version.inspect} (this gem reads #{READABLE_VERSIONS.join(' and ')})"
        end

        Document.new(data)
      rescue JSON::ParserError => e
        raise Unreadable, "the manifest is not valid JSON (#{e.message.lines.first.to_s.strip})"
      end

      # `{ audience => { wire => Wire } }` for a version 1 or 2 manifest.
      def self.wires_in(data)
        wires = Hash.new { |hash, audience| hash[audience] = {} }
        list(data, "flags").each do |flag|
          key = string!(flag, "key")
          type = flag_type(flag)
          flag_wires(data["version"], flag).each do |audience, names|
            names.each do |name|
              wires[audience][name] = Wire.new(audience: audience, name: name, type: type, source: :flag, key: key, until: nil)
            end
          end
        end
        list(data, "tombstones").each do |tombstone|
          key = string!(tombstone, "key")
          serve = tombstone.fetch("serve", {})
          raise Unreadable, "tombstone #{key} serve is not an object" unless serve.is_a?(Hash)

          last = tombstone["until"] && date!(tombstone["until"], "tombstone #{key} until")
          serve.each do |audience, statics|
            raise Unreadable, "tombstone #{key} serve.#{audience} is not an object" unless statics.is_a?(Hash)

            statics.each do |name, value|
              wires[audience][name] = Wire.new(audience: audience, name: name, type: value_type(value, "tombstone #{key} #{name}"),
                                               source: :static, key: key, until: last)
            end
          end
        end
        wires.transform_values(&:freeze).freeze
      end

      def self.list(data, field)
        value = data.fetch(field, [])
        raise Unreadable, "#{field} is not an array" unless value.is_a?(Array)
        raise Unreadable, "#{field} holds an entry that is not an object" unless value.all?(Hash)

        value
      end

      def self.string!(entry, field)
        value = entry[field]
        raise Unreadable, "an entry has no #{field}" unless value.is_a?(String) && !value.empty?

        value
      end

      # Version 1 wrote `audiences` as `{ audience => first wire }` and listed
      # aliases under `wires`; version 2 writes `{ audience => [wires] }`.
      def self.flag_wires(version, flag)
        audiences = version == 1 ? flag.fetch("wires") { flag.fetch("audiences", {}) } : flag.fetch("audiences", {})
        raise Unreadable, "flag #{flag['key']} audiences is not an object" unless audiences.is_a?(Hash)

        audiences.to_h do |audience, names|
          names = Array(names)
          raise Unreadable, "flag #{flag['key']} lists a wire for #{audience} that is not a string" unless names.all?(String)

          [ audience, names ]
        end
      end

      # A flag's `type`, or (for a version 1 file written before `type`
      # existed) boolean when every value is one.
      def self.flag_type(flag)
        type = flag["type"]
        return type if TYPES.include?(type)
        raise Unreadable, "flag #{flag['key']} has an unknown type #{type.inspect}" unless type.nil?

        values = Array(flag["values"])
        !values.empty? && values.all? { |value| [ true, false ].include?(value) } ? "boolean" : "string"
      end

      def self.value_type(value, label)
        return "boolean" if [ true, false ].include?(value)
        return "string" if value.is_a?(String)

        raise Unreadable, "#{label} serves #{value.inspect}, which is neither a boolean nor a string"
      end

      def self.date!(value, label)
        Date.iso8601(value.to_s)
      rescue Date::Error
        raise Unreadable, "#{label} #{value.inspect} is not a YYYY-MM-DD date"
      end

      def initialize(registry: StandardFlags.registry)
        @registry = registry
      end

      def to_h
        {
          "version" => VERSION,
          "audiences" => audiences,
          "flags" => @registry.definitions.sort_by(&:key).map { |definition| flag(definition) },
          "tombstones" => @registry.tombstones.values.sort_by(&:key).map { |tombstone| tombstone(tombstone) }
        }
      end

      def render
        "#{JSON.pretty_generate(to_h)}\n"
      end

      # The SHA-256 (hex) of `render`: the committed file's bytes, which
      # generated client code names in its header.
      def digest
        Digest::SHA256.hexdigest(render)
      end

      private

      def audiences
        names = @registry.audiences
        names |= @registry.tombstones.values.flat_map { |tombstone| tombstone.serve.keys }
        names |= StandardFlags.config.audiences&.keys || []
        names.sort.to_h do |name|
          audience = @registry.audience(name)
          [ name.to_s, { "public" => audience ? audience.public? : false } ]
        end
      end

      def flag(definition)
        entry = {
          "key" => definition.key.to_s,
          "kind" => definition.kind.to_s,
          "type" => definition.boolean? ? "boolean" : "string",
          "values" => definition.allowed_values.map { |value| wire(value) },
          "default" => default(definition),
          "audiences" => definition.exposure.sort.to_h { |audience, wires| [ audience.to_s, wires ] },
          "min_client" => definition.min_client.sort.to_h { |platform, version| [ platform, version.to_s ] }
        }
        entry["permanent"] = definition.permanent? if LIFECYCLE_KINDS.include?(definition.kind)
        entry["remove_by"] = definition.remove_by.iso8601 if definition.remove_by
        entry["final"] = wire(definition.final) unless definition.final.nil?
        entry
      end

      def tombstone(tombstone)
        entry = { "key" => tombstone.key.to_s, "removed" => tombstone.removed.iso8601 }
        return entry if tombstone.serve.empty?

        entry.merge(
          "serve" => tombstone.serve.sort.to_h { |audience, statics| [ audience.to_s, statics.sort.to_h ] },
          "until" => tombstone.serve_until.iso8601,
          "until_clients" => tombstone.until_clients.sort.to_h { |platform, version| [ platform, version.to_s ] }
        )
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
  end
end
