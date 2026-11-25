require "date"
require "digest"
require "json"

module StandardFlags
  # What one client audience is told: OFREP evaluation entries, built from
  # the same evaluation the server uses. One builder feeds every outlet: the
  # OFREP endpoint (StandardFlags::OFREP::Controller), bootstrap embeds
  # (`StandardFlags.payload(:mobile, format: :ofrep)`), device check-ins and
  # MCP whoami.
  #
  #   result = StandardFlags::Delivery.build(:mobile, StandardFlags::Context.wrap(account, client: client))
  #   result.to_h  # => { "flags" => [...], "metadata" => { "version" => result.etag } }
  #
  # The entries are, ordered by wire name:
  #
  # * one per wire name (aliases included) of every flag exposed to the
  #   audience whose `min_client:` the client meets;
  # * one per static wire of a tombstone still serving this audience and
  #   client (`serve:`, through `until:` in UTC, below `until_clients:`),
  #   with reason STATIC.
  #
  # An entry is `{ "key", "value", "variant", "reason" }`, or, for a flag
  # whose evaluation failed, `{ "key", "errorCode", "errorDetails" }` (OFREP's
  # evaluationFailure), so the client uses its code default; one bad flag
  # never breaks the rest. Reasons are the gem's (KILL_SWITCH and ENV_PIN
  # included). Nothing else leaves the server: no flag keys, rule IDs, env
  # var names, unit keys or flags the audience isn't exposed to.
  #
  # The ETag is the SHA-256 (hex) of the RFC 8785 (JCS) canonical JSON of
  # `{ "audience": "<name>", "flags": [<entries>] }`: sorted keys, no
  # whitespace, strings as UTF-8 with only the escapes JCS requires (they
  # may be non-ASCII); no numbers occur. It
  # depends only on what this client is told, never on the config revision,
  # so a client that switches user can never be answered 304 for answers
  # that differ.
  module Delivery
    # The error codes OFREP allows on a flag; any other is sent as GENERAL.
    ERROR_CODES = [ ErrorCode::PARSE_ERROR, ErrorCode::TARGETING_KEY_MISSING,
                    ErrorCode::INVALID_CONTEXT, ErrorCode::GENERAL ].freeze
    ERROR_DETAILS = "the flag could not be evaluated; use the code default".freeze

    # One OFREP evaluation entry.
    Entry = Data.define(:key, :value, :variant, :reason, :error_code, :error_details) do
      def self.evaluated(key, value, variant, reason)
        new(key: key, value: value, variant: variant, reason: reason, error_code: nil, error_details: nil)
      end

      def self.failed(key, error_code)
        code = ERROR_CODES.include?(error_code) ? error_code : ErrorCode::GENERAL
        new(key: key, value: nil, variant: nil, reason: nil, error_code: code, error_details: ERROR_DETAILS)
      end

      def error?
        !error_code.nil?
      end

      # The OFREP JSON object.
      def to_h
        return { "key" => key, "errorCode" => error_code, "errorDetails" => error_details } if error?

        { "key" => key, "value" => value, "reason" => reason, "variant" => variant }
      end
    end

    # The entries for one audience and client, and their ETag.
    Result = Data.define(:audience, :entries, :etag) do
      def [](key)
        entries.find { |entry| entry.key == key.to_s }
      end

      def flags
        entries.map(&:to_h)
      end

      # OFREP's bulk response body. `metadata.version` is the ETag.
      def to_h
        { "flags" => flags, "metadata" => { "version" => etag } }
      end

      # The ETag header value (a strong, quoted tag).
      def etag_header
        %("#{etag}")
      end

      # Whether an If-None-Match header names this result's ETag (quoted or
      # not, weak or strong). `*` never matches.
      def fresh?(if_none_match)
        return false if if_none_match.nil?

        if_none_match.to_s.split(",").any? do |tag|
          tag.strip.delete_prefix("W/").delete_prefix('"').delete_suffix('"') == etag
        end
      end
    end

    module_function

    # The entries `context` (and its client) gets for `audience`. `only:`
    # keeps a single wire name (the single-flag endpoint). With
    # `config.audiences` set, an undeclared audience raises when
    # `config.strict` is on and is empty otherwise.
    def build(audience, context, registry: StandardFlags.registry, today: utc_today, only: nil)
      audience = audience.to_sym
      context = Context.wrap(context)
      return empty(audience) unless declared?(audience)

      only = only&.to_s
      reader = Reader.new(registry, context)
      client = context.client
      entries = registry.wires(audience).filter_map do |wire, definition|
        next if only && wire != only
        next unless definition.deliverable_to?(client)

        entry(wire, definition, reader.evaluate(definition.key))
      end
      registry.deprecated_wires(audience).each do |wire, value, tombstone|
        next if only && wire != only
        next unless tombstone.serving?(today) && tombstone.serves_client?(client)

        entries << Entry.evaluated(wire, value, static_variant(value), Reason::STATIC)
      end
      finish(audience, entries)
    end

    # The entries a request made before authentication gets: only for a
    # `public: true` audience (anything else raises), evaluated with no
    # actors. Every unit resolves to nothing except the audience's own
    # `unit:`, whose key is `targeting_key`; segments are skipped.
    def build_anonymous(audience, client:, targeting_key: nil, registry: StandardFlags.registry, today: utc_today, only: nil)
      declared = registry.audience(audience)
      raise ArgumentError, "audience :#{audience} is not a public audience (config.audiences)" unless declared&.public?

      anonymous = registry.units.each_key.reduce(registry) do |copy, unit|
        copy.with_unit_key(unit, unit == declared.unit ? targeting_key : nil)
      end
      build(audience, AnonymousContext.new(client: client), registry: anonymous, today: today, only: only)
    end

    # Tombstones' `until:` dates are compared with today's date in UTC, so
    # every host (whatever its time zone) switches a wire off at the same
    # instant and agrees on the ETag.
    def utc_today
      Time.now.utc.to_date
    end

    # The canonical JSON the ETag hashes: object keys sorted, no whitespace.
    def canonical_json(value)
      JSON.generate(sort_keys(value))
    end

    def etag(audience, entries)
      Digest::SHA256.hexdigest(canonical_json({ "audience" => audience.to_s, "flags" => entries.map(&:to_h) }))
    end

    def entry(wire, definition, evaluation)
      return Entry.failed(wire, evaluation.error_code) if evaluation.error?

      value = evaluation.value
      value = value.to_s unless definition.boolean?
      Entry.evaluated(wire, value, evaluation.variant, evaluation.reason)
    end

    def static_variant(value)
      return value if value.is_a?(String)

      value ? "on" : "off"
    end

    def declared?(audience)
      declared = StandardFlags.config.audiences
      return true if declared.nil? || declared.key?(audience)
      raise ArgumentError, "audience :#{audience} is not in config.audiences" if StandardFlags.config.strict?

      false
    end

    def empty(audience)
      finish(audience, [])
    end

    def finish(audience, entries)
      entries = entries.sort_by(&:key).freeze
      Result.new(audience: audience, entries: entries, etag: etag(audience, entries))
    end

    def sort_keys(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, sort_keys(value[key]) ] }
      when Array then value.map { |item| sort_keys(item) }
      else value
      end
    end
  end
end
