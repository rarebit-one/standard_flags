require "spec_helper"
require "time"

# Runs every case in conformance/runtime: a stored rule, its
# cohorts and memberships, and a context in; the evaluation out. Like the
# other conformance fixtures, these are meant to run in every evaluator.
RSpec.describe "runtime conformance fixtures" do
  fixtures = Dir[ConformanceRegistry.path("runtime/*.json")].sort

  it "has fixture files" do
    expect(fixtures).not_to be_empty
  end

  define_registry = lambda do |spec|
    StandardFlags.define do
      Array(spec["units"]).each { |name| unit name.to_sym, from: ->(ctx) { ctx.actor(name) } }
      Array(spec["flags"]).each do |flag|
        attributes = flag.except("kind", "key").transform_keys(&:to_sym)
        public_send(flag.fetch("kind"), flag.fetch("key"), **attributes)
      end
    end
  end

  fill_store = lambda do |example|
    store = StandardFlags::Runtime::MemoryStore.new
    example.fetch("rules", []).each do |rule|
      store.put_rule(rule.fetch("key"), **rule.except("key").transform_keys(&:to_sym))
    end
    example.fetch("cohorts", []).each do |cohort|
      store.put_cohort(cohort.fetch("key"), unit: cohort.fetch("unit"), archived_at: cohort["archived"] ? Time.now : nil)
    end
    example.fetch("memberships", []).each do |m|
      store.add_member(rule: m["rule"], cohort: m["cohort"], unit: m.fetch("unit"), unit_key: m.fetch("unit_key"),
                       value: m.fetch("value"), expires_at: m["expires_at"] && Time.iso8601(m["expires_at"]))
    end
    store
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
          StandardFlags.config.runtime_store = fill_store.call(example)
          context = example.fetch("context", {})
          segments = Array(context["segments"])
          StandardFlags.config.segment_resolver = ->(name, _context) { segments.include?(name) }
          evaluation = StandardFlags.evaluate(example.fetch("flag"), for: StandardFlags::Context.new(
            env: example.fetch("environment"), actors: context.fetch("units", {}), client: context.fetch("client", {})
          ))

          expected = { "error_code" => nil, "rule_id" => nil }.merge(example.fetch("expected"))
          actual = ConformanceRegistry.wire(evaluation).except("source_env_var").merge("rule_id" => evaluation.rule_id)
          expect(actual).to eq(expected)
        end
      end
    end
  end
end
