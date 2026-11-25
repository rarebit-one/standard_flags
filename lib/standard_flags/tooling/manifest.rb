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
    #     ],
    #     "clients": {
    #       "android_app": { "platform": "android", "group": null, "min_version": "0.4.0", "since": "2026-12-01",
    #                        "grace": 7, "recommended": "0.5.0", "available": "0.5.0",
    #                        "store_url": "https://example.com/app", "store_lookup": false }
    #     }
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
    # * `clients` is the client registry (`client :name, ...`) as declared in
    #   code, keyed by name: every attribute is present, null when not
    #   declared, `grace` in whole days, and `store_lookup` only says whether
    #   one is configured. ENV break-glass pins and store lookup answers are
    #   runtime state and never appear.
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

      # A parsed manifest of either version: the document as given, the wires
      # it declares (`{ audience => { wire => Wire } }`) and its audiences
      # (`{ audience => public? }`; empty for version 1, which didn't say).
      class Document
        attr_reader :version, :data, :wires, :audiences

        def initialize(data)
          @data = data
          @version = data["version"]
          @audiences = Manifest.audiences_in(data)
          Manifest.check_clients!(data)
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
      # Unreadable for anything conformance/schema/manifest.schema.json
      # rejects, and for what a schema can't say: a version written as a
      # non-integer (`2.0`), dates that aren't calendar dates, and a wire
      # listed twice for one audience (by two flags, a flag and a tombstone,
      # or twice in one list), which the registry never writes.
      def self.read(source)
        data = source.is_a?(String) ? JSON.parse(source) : source
        raise Unreadable, "the manifest is not a JSON object" unless data.is_a?(Hash)

        version = data["version"]
        unless version.is_a?(Integer) && READABLE_VERSIONS.include?(version)
          raise Unreadable, "unknown manifest version #{version.inspect} (this gem reads #{READABLE_VERSIONS.join(' and ')})"
        end
        if version >= 2
          missing = %w[audiences flags tombstones clients].reject { |field| data.key?(field) }
          raise Unreadable, "a version #{version} manifest needs #{missing.join(', ')}" unless missing.empty?
        end

        Document.new(data)
      rescue JSON::ParserError => e
        raise Unreadable, "the manifest is not valid JSON (#{e.message.lines.first.to_s.strip})"
      end

      # `{ audience => public? }` from a version 2 manifest's `audiences`.
      def self.audiences_in(data)
        return {}.freeze unless data["version"].to_i >= 2

        audiences = data["audiences"]
        raise Unreadable, "audiences is not an object" unless audiences.is_a?(Hash)

        audiences.to_h do |name, options|
          public = options.is_a?(Hash) ? options["public"] : nil
          raise Unreadable, "audiences.#{name} needs \"public\": true or false" unless [ true, false ].include?(public)

          [ name, public ]
        end.freeze
      end

      CLIENT_FIELDS = %w[platform group min_version since grace recommended available store_url store_lookup].freeze

      # A version 2 manifest's `clients`: an object of client name => every
      # field in CLIENT_FIELDS, typed as the writer writes them.
      def self.check_clients!(data)
        return unless data["version"].to_i >= 2

        clients = data["clients"]
        raise Unreadable, "clients is not an object" unless clients.is_a?(Hash)

        clients.each do |name, client|
          label = "clients.#{name}"
          raise Unreadable, "#{label} is not an object" unless client.is_a?(Hash)
          raise Unreadable, "#{label} needs exactly #{CLIENT_FIELDS.join(', ')}" unless client.keys.sort == CLIENT_FIELDS.sort
          raise Unreadable, "#{label} platform is not a string" unless client["platform"].is_a?(String) && !client["platform"].empty?

          %w[group min_version recommended available store_url].each do |field|
            raise Unreadable, "#{label} #{field} is not a string or null" unless client[field].nil? || client[field].is_a?(String)
          end
          date!(client["since"], "#{label} since") unless client["since"].nil?
          raise Unreadable, "#{label} grace is not a whole number of days" unless client["grace"].is_a?(Integer) && client["grace"] >= 0
          raise Unreadable, "#{label} store_lookup is not true or false" unless [ true, false ].include?(client["store_lookup"])
        end
      end

      # `{ audience => { wire => Wire } }` for a version 1 or 2 manifest.
      def self.wires_in(data)
        wires = Hash.new { |hash, audience| hash[audience] = {} }
        add = lambda do |wire, owner|
          if wires[wire.audience].key?(wire.name)
            raise Unreadable, "wire #{wire} is listed twice (#{owner}); a manifest tells an audience each wire once"
          end

          wires[wire.audience][wire.name] = wire
        end
        list(data, "flags").each do |flag|
          key = string!(flag, "key")
          date!(flag["remove_by"], "flag #{key} remove_by") if flag.key?("remove_by")
          type = flag_type(data["version"], flag)
          flag_wires(data["version"], flag).each do |audience, names|
            names.each do |name|
              add.call(Wire.new(audience: audience, name: name, type: type, source: :flag, key: key, until: nil), "flag #{key}")
            end
          end
        end
        list(data, "tombstones").each do |tombstone|
          key = string!(tombstone, "key")
          date!(tombstone["removed"], "tombstone #{key} removed") if data["version"] >= 2 || tombstone.key?("removed")
          unless tombstone.key?("serve")
            raise Unreadable, "tombstone #{key} has until or until_clients without serve" if tombstone.key?("until") || tombstone.key?("until_clients")

            next
          end
          serve = tombstone["serve"]
          raise Unreadable, "tombstone #{key} serve is not a non-empty object" unless serve.is_a?(Hash) && !serve.empty?
          raise Unreadable, "tombstone #{key} serve needs until (the last day its wires are served)" unless tombstone.key?("until")
          if data["version"] >= 2 && !tombstone["until_clients"].is_a?(Hash)
            raise Unreadable, "tombstone #{key} serve needs until_clients (an object, {} when there are none)"
          end

          last = date!(tombstone["until"], "tombstone #{key} until")
          serve.each do |audience, statics|
            raise Unreadable, "tombstone #{key} serve.#{audience} is not an object" unless statics.is_a?(Hash)

            statics.each do |name, value|
              add.call(Wire.new(audience: audience, name: name, type: value_type(value, "tombstone #{key} #{name}"),
                                source: :static, key: key, until: last), "tombstone #{key}")
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
          if version >= 2 && !(names.is_a?(Array) && !names.empty?)
            raise Unreadable, "flag #{flag['key']} audiences.#{audience} is not a non-empty array of wire names"
          end

          names = Array(names)
          raise Unreadable, "flag #{flag['key']} lists a wire for #{audience} that is not a string" unless names.all?(String)

          [ audience, names ]
        end
      end

      # A flag's `type`. Version 2 requires it, with values (and default and
      # final) of that type. A version 1 file written before `type` existed
      # reads as boolean when every value is one.
      def self.flag_type(version, flag)
        type = flag["type"]
        if version >= 2
          raise Unreadable, "flag #{flag['key']} has an unknown type #{type.inspect}" unless TYPES.include?(type)

          check_values!(flag, type)
          return type
        end
        return type if TYPES.include?(type)
        raise Unreadable, "flag #{flag['key']} has an unknown type #{type.inspect}" unless type.nil?

        values = Array(flag["values"])
        !values.empty? && values.all? { |value| [ true, false ].include?(value) } ? "boolean" : "string"
      end

      def self.check_values!(flag, type)
        typed = type == "boolean" ? ->(value) { [ true, false ].include?(value) } : ->(value) { value.is_a?(String) }
        values = flag["values"]
        unless values.is_a?(Array) && values.size >= 2 && values.all?(&typed) && values.uniq.size == values.size
          raise Unreadable, "flag #{flag['key']} values must list at least two unique #{type} values"
        end

        default = flag["default"]
        defaults = default.is_a?(Hash) ? default.values : [ default ]
        raise Unreadable, "flag #{flag['key']} default is not a #{type}" unless defaults.all?(&typed)
        raise Unreadable, "flag #{flag['key']} final is not a #{type}" if flag.key?("final") && !typed.call(flag["final"])
      end

      def self.value_type(value, label)
        return "boolean" if [ true, false ].include?(value)
        return "string" if value.is_a?(String)

        raise Unreadable, "#{label} serves #{value.inspect}, which is neither a boolean nor a string"
      end

      # A YYYY-MM-DD calendar date (2026-02-30 is refused).
      def self.date!(value, label)
        raise Date::Error unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        Date.iso8601(value)
      rescue Date::Error
        raise Unreadable, "#{label} #{value.inspect} is not a YYYY-MM-DD calendar date"
      end

      def initialize(registry: StandardFlags.registry)
        @registry = registry
      end

      def to_h
        {
          "version" => VERSION,
          "audiences" => audiences,
          "flags" => @registry.definitions.sort_by(&:key).map { |definition| flag(definition) },
          "tombstones" => @registry.tombstones.values.sort_by(&:key).map { |tombstone| tombstone(tombstone) },
          "clients" => @registry.clients.sort_by { |name, _| name.to_s }.to_h { |name, client| [ name.to_s, client(client) ] }
        }
      end

      # The generator options are spelled out (they are JSON.pretty_generate's)
      # so the bytes, and the digest, don't depend on the json gem's defaults.
      FORMAT = { indent: "  ", space: " ", object_nl: "\n", array_nl: "\n" }.freeze

      def self.format(data)
        "#{JSON.generate(data, FORMAT)}\n"
      end

      def render
        self.class.format(to_h)
      end

      # The SHA-256 (hex) of `render`: the canonical manifest (LF line
      # endings, ending in one newline), which generated client code names
      # in its header.
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

      def client(client)
        {
          "platform" => client.platform,
          "group" => client.group&.to_s,
          "min_version" => client.min_version&.to_s,
          "since" => client.since&.iso8601,
          "grace" => client.grace_days,
          "recommended" => client.recommended&.to_s,
          "available" => client.available&.to_s,
          "store_url" => client.store_url,
          "store_lookup" => client.store_lookup?
        }
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
