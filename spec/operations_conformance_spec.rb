require "spec_helper"

# Runs every case in conformance/operations: operations applied
# in order to an empty store, then evaluations. Like the other conformance
# fixtures, these are meant to hold for every implementation of the write
# path and evaluator.
RSpec.describe "write-path conformance fixtures" do
  fixtures = Dir[ConformanceRegistry.path("operations/*.json")].sort
  actor = StandardFlags::Actor.system("conformance")

  it "has fixture files" do
    expect(fixtures).not_to be_empty
  end

  define_registry = lambda do |spec|
    StandardFlags.define do
      Array(spec["units"]).each { |name| unit name.to_sym, from: ->(ctx) { ctx.actor(name) } }
      Array(spec["flags"]).each do |flag|
        attributes = flag.except("kind", "key").transform_keys(&:to_sym)
        attributes[:bucketing] = attributes[:bucketing]&.transform_keys(&:to_sym)
        public_send(flag.fetch("kind"), flag.fetch("key"), **attributes.compact)
      end
    end
  end

  run_step = lambda do |step|
    operation = StandardFlags::Operations.const_get(step.fetch("op").split("_").map(&:capitalize).join)
    args = step.fetch("args", {}).transform_keys(&:to_sym)
    operation.call(step.fetch("target"), actor: actor, reason: "conformance", expected_revision: step["expected_revision"], **args)
  end

  fixtures.each do |file|
    fixture = ConformanceRegistry.load(file)

    describe File.basename(file) do
      fixture.fetch("cases").each do |example|
        it example.fetch("name") do
          StandardFlags::Testing.deactivate!
          define_registry.call(fixture.fetch("registry"))
          StandardFlags.config.env_source = example.fetch("env_vars", {})
          StandardFlags.config.runtime_rules = true
          StandardFlags.config.runtime_store = StandardFlags::Runtime::MemoryStore.new

          outcomes = example.fetch("steps").map { |step| run_step.call(step).then { |r| r.success? ? nil : r.code.to_s } }
          expect(outcomes).to eq(example.fetch("steps").map { |step| step["fails"] })

          actual = example.fetch("checks").map do |check|
            evaluation = StandardFlags.evaluate(check.fetch("flag"), for: StandardFlags::Context.new(
              env: check.fetch("environment"), actors: check.fetch("context").fetch("units", {})
            ))
            ConformanceRegistry.wire(evaluation).except("source_env_var").merge("rule_id" => evaluation.rule_id)
          end
          expect(actual).to eq(example.fetch("checks").map { |check| check.fetch("expected") })
        end
      end
    end
  end
end
