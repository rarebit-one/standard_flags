require "spec_helper"

# Every runtime fixture case whose rule stores a version range in another
# form (a RubyGems requirement, or neutral with spaces or shorthands) runs a
# second time with the range in canonical neutral form, and must evaluate
# the same: stored ranges keep their meaning whichever syntax holds them.
RSpec.describe "runtime conformance fixtures with neutral version ranges" do
  define_registry = lambda do |spec|
    StandardFlags.define do
      Array(spec["units"]).each { |name| unit name.to_sym, from: ->(ctx) { ctx.actor(name) } }
      Array(spec["flags"]).each do |flag|
        public_send(flag.fetch("kind"), flag.fetch("key"), **flag.except("kind", "key").transform_keys(&:to_sym))
      end
    end
  end

  # The case's rules with every version range rewritten to canonical
  # neutral form.
  neutral_store = lambda do |rules|
    StandardFlags::Runtime::MemoryStore.new.tap do |store|
      rules.each do |rule|
        attributes = rule.except("key")
        versions = rule["conditions"].is_a?(Hash) && rule["conditions"]["versions"]
        if versions.is_a?(Hash)
          neutral = versions.transform_values { |range| StandardFlags::VersionRange.parse(range)&.to_s || range }
          attributes = attributes.merge("conditions" => rule["conditions"].merge("versions" => neutral))
        end
        store.put_rule(rule.fetch("key"), **attributes.transform_keys(&:to_sym))
      end
    end
  end

  Dir[ConformanceRegistry.path("runtime/*.json")].sort.each do |file|
    fixture = ConformanceRegistry.load(file)
    fixture.fetch("cases").each do |example|
      rules = example.fetch("rules", [])
      legacy = rules.flat_map do |rule|
        versions = rule["conditions"].is_a?(Hash) ? rule["conditions"]["versions"] : nil
        versions.is_a?(Hash) ? versions.values : []
      end
      rewritten = legacy.select { |range| (parsed = StandardFlags::VersionRange.parse(range)) && parsed.to_s != range }
      next if rewritten.empty?

      it "#{File.basename(file)}: #{example.fetch('name')}" do
        StandardFlags::Testing.deactivate!
        define_registry.call(fixture.fetch("registry"))
        StandardFlags.config.runtime_rules = true
        StandardFlags.config.runtime_store = neutral_store.call(rules)
        context = example.fetch("context", {})
        evaluation = StandardFlags.evaluate(example.fetch("flag"), for: StandardFlags::Context.new(
          env: example.fetch("environment"), actors: context.fetch("units", {}), client: context.fetch("client", {})
        ))

        expected = { "error_code" => nil, "rule_id" => nil }.merge(example.fetch("expected"))
        expect(ConformanceRegistry.wire(evaluation).except("source_env_var").merge("rule_id" => evaluation.rule_id)).to eq(expected)
      end
    end
  end
end
