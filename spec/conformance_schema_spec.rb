require "spec_helper"
require "json_schemer"

# Every fixture under conformance/ validates against
# conformance/schema/fixture.schema.json, which other runners can use too.
RSpec.describe "conformance fixture schema" do
  schema = JSONSchemer.schema(Pathname.new(ConformanceRegistry.path("schema/fixture.schema.json")))
  files = Dir[ConformanceRegistry.path("**/*.json")].reject { |file| file.include?("/schema/") }.sort

  it "covers every fixture file" do
    expect(files.map { |file| file.delete_prefix("#{ConformanceRegistry::ROOT}/") }).to include(
      "resolution.json", "runtime/rules.json", "operations/write_path.json", "bucket_vectors.json",
      "versions/version_ranges.json", "versions/legacy_ranges.json", "wire/delivery.json", "wire/client_state.json",
      "wire/client_status.json"
    )
  end

  files.each do |file|
    it "validates #{file.delete_prefix("#{ConformanceRegistry::ROOT}/")}" do
      errors = schema.validate(ConformanceRegistry.load(file)).first(5).map { |error| error["error"] }
      expect(errors).to eq([])
    end
  end

  it "rejects a fixture without a scope, or a delivery entry that isn't OFREP" do
    expect(schema.valid?({ "description" => "x", "suite" => "evaluation", "registry" => { "flags" => [] }, "cases" => [] })).to be(false)
    delivery = ConformanceRegistry.load(ConformanceRegistry.path("wire/delivery.json"))
    delivery["cases"].first["expected"]["flags"].first["rule_id"] = "allow"
    expect(schema.valid?(delivery)).to be(false)
  end

  it "keeps server-only behaviour out of the wire scope" do
    scopes = files.to_h { |file| [ File.basename(file), ConformanceRegistry.load(file).fetch("scope") ] }
    expect(scopes.select { |_, scope| scope == "wire" }.keys.sort).to eq(%w[client_state.json client_status.json delivery.json version_ranges.json])
  end
end
