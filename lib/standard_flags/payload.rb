require "digest"
require "json"

module StandardFlags
  # The capability payload a client audience sees: `{ wire_name => value }`
  # for flags that declare `expose:` for that audience, and nothing else.
  # Unexposed keys never appear, and wire names are decoupled from keys so a
  # renamed or removed flag doesn't break a shipped client.
  module Payload
    module_function

    def build(registry, audience, context)
      reader = Reader.new(registry, context)
      registry.exposed(audience).to_h do |definition|
        [ definition.wire_name(audience), wire_value(definition, reader.evaluate(definition.key)) ]
      end
    end

    # A stable hash of the evaluated result (not the config), suitable for an
    # ETag: switching user changes the digest whenever the answers differ.
    def digest(payload)
      Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h))
    end

    def wire_value(definition, evaluation)
      definition.boolean? ? evaluation.value : evaluation.value.to_s
    end
  end
end
