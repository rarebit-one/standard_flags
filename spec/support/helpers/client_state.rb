require "json"

# A reference client for conformance/wire/client_state.json: what a client
# library does with OFREP bulk payloads. The Kotlin and TypeScript libraries
# implement the same rules (conformance/README.md); the gem itself never
# runs this outside its specs.
class ClientStateReference
  # A version is sent back quoted in If-None-Match, so only an ETag's
  # characters are kept (printable ASCII other than space and `"`), and at
  # most 256 of them, well under any proxy's header limit.
  VERSION = /\A[\x21\x23-\x7E]{1,256}\z/

  attr_reader :version

  def initialize(declared, limits)
    @declared = declared
    @max_bytes = limits.fetch("max_bytes")
    @max_flags = limits.fetch("max_flags")
    @max_nesting = limits.fetch("max_nesting")
    @entries = nil
    @version = nil
  end

  # Takes raw payload bytes; returns whether the payload was accepted. A
  # rejected payload leaves the last good one (and its version) in place.
  def receive(raw)
    document = parse(raw)
    return false unless document

    @entries = document["flags"].to_h { |entry| [ entry["key"], entry ] }
    version = document.dig("metadata", "version")
    @version = version.is_a?(String) && version.match?(VERSION) ? version : nil
    true
  end

  # A 304: nothing changes.
  def not_modified
    true
  end

  def reads
    @declared.to_h { |key, declaration| [ key, read(declaration, @entries&.fetch(key, nil)) ] }
  end

  private

  def parse(raw)
    return nil if raw.bytesize > @max_bytes

    # Strict RFC 8259: no NaN or Infinity, comments, trailing commas, control
    # characters in strings or bad escapes. Nesting is measured here, not by
    # the json gem, whose max_nesting lets an empty innermost container
    # through: every object and array counts, the top level being 1.
    document = JSON.parse(raw, max_nesting: false, allow_nan: false)
    return nil if depth(document) > @max_nesting
    return nil unless document.is_a?(Hash) && document["flags"].is_a?(Array)
    return nil if document.key?("metadata") && !document["metadata"].is_a?(Hash)

    flags = document["flags"]
    return nil if flags.size > @max_flags
    return nil unless flags.all? { |entry| entry.is_a?(Hash) && entry["key"].is_a?(String) && !entry["key"].empty? }
    return nil unless flags.map { |entry| entry["key"] }.uniq.size == flags.size

    document
  rescue JSON::ParserError
    nil
  end

  def depth(value)
    case value
    when Hash then 1 + (value.values.map { |item| depth(item) }.max || 0)
    when Array then 1 + (value.map { |item| depth(item) }.max || 0)
    else 0
    end
  end

  def read(declaration, entry)
    default = declaration.fetch("default")
    value = usable_value(declaration, entry)
    return { "state" => "not_loaded", "value" => default, "reason" => nil } if value.nil?

    reason = entry["reason"].is_a?(String) ? entry["reason"] : nil
    return { "state" => "loaded", "value" => value, "reason" => reason } if declaration["type"] == "string"

    effective = declaration["ceiling"] ? (default && value) : value
    { "state" => effective ? "on" : "off", "value" => effective, "reason" => effective == value ? reason : nil }
  end

  # The entry's value when the client can use it, else nil.
  def usable_value(declaration, entry)
    return nil if entry.nil? || !entry["errorCode"].nil? || !entry.key?("value")

    value = entry["value"]
    if declaration["type"] == "boolean"
      value if [ true, false ].include?(value)
    elsif value.is_a?(String) && (declaration["values"].nil? || declaration["values"].include?(value))
      value
    end
  end
end
