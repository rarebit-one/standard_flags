require "json"

# Small version 2 manifests for reader and schema specs.
module ManifestDocs
  FLAG = { "key" => "a", "kind" => "flag", "type" => "boolean", "values" => [ true, false ], "default" => false,
           "audiences" => { "web" => [ "a" ] }, "min_client" => {} }.freeze
  TOMBSTONE = { "key" => "t", "removed" => "2026-01-01", "serve" => { "web" => { "w" => true } }, "until" => "2027-01-01",
                "until_clients" => {} }.freeze

  module_function

  def flag(**changes)
    FLAG.merge(changes.transform_keys(&:to_s))
  end

  def tombstone(**changes)
    TOMBSTONE.merge(changes.transform_keys(&:to_s))
  end

  # JSON text; `fields` replace top-level members.
  def doc(**fields)
    JSON.generate({ "version" => 2, "audiences" => { "web" => { "public" => false } }, "flags" => [], "tombstones" => [] }
                    .merge(fields.transform_keys(&:to_s)))
  end
end
