require "spec_helper"

# Runs every case in conformance/ (shipped in the gem). The same files are meant to
# run in every evaluator (Ruby here; Kotlin and TypeScript clients later), so
# they can't drift apart on what a flag evaluates to.
RSpec.describe "conformance fixtures" do
  fixtures = Dir[ConformanceRegistry.path("*.json")].sort

  it "has fixture files" do
    expect(fixtures).not_to be_empty
  end

  fixtures.reject { |file| file.end_with?("bucket_vectors.json") }.each do |file|
    fixture = ConformanceRegistry.load(file)

    describe File.basename(file) do
      fixture.fetch("cases").each do |example|
        it example.fetch("name") do
          StandardFlags::Testing.deactivate!
          ConformanceRegistry.define(fixture.fetch("registry"))
          StandardFlags.config.env_source = example.fetch("env_vars", {})
          StandardFlags.config.strict = example.fetch("strict", true)
          context = StandardFlags::Context.new(env: example.fetch("environment"))

          evaluation = StandardFlags.evaluate(example.fetch("flag"), for: context)

          expected = { "error_code" => nil, "source_env_var" => nil }.merge(example.fetch("expected"))
          expect(ConformanceRegistry.wire(evaluation)).to eq(expected)
        end
      end
    end
  end

  describe "bucket_vectors.json" do
    vectors = ConformanceRegistry.load(ConformanceRegistry.path("bucket_vectors.json"))

    vectors.fetch("vectors").each do |vector|
      label = [ "v#{vector['version']}", vector["decision"], vector["salt"].inspect, vector["unit_key"].inspect ]
      it label.compact.join(" ") do
        bucket =
          case vector.fetch("version")
          when 1 then StandardFlags::Bucket.v1(vector["salt"], vector["unit_key"])
          when 2 then StandardFlags::Bucket.v2(vector.fetch("decision"), vector["salt"], vector["unit_key"])
          end

        expect(bucket).to eq(vector.fetch("bucket"))
      end
    end
  end
end
