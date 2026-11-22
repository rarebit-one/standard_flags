require "json"

# Builds a registry from a conformance fixture's "registry" block. Other
# evaluators (Kotlin, TypeScript) implement the same mapping.
module ConformanceRegistry
  module_function

  def load(file)
    JSON.parse(File.read(file))
  end

  def define(spec)
    StandardFlags.define do
      Array(spec["flags"]).each do |flag|
        attributes = flag.except("kind", "key").transform_keys(&:to_sym)
        public_send(flag.fetch("kind"), flag.fetch("key"), **attributes)
      end
      Array(spec["tombstones"]).each { |t| tombstone(t.fetch("key"), removed: t.fetch("removed")) }
    end
  end

  # Evaluation values in the wire shape the fixtures use: booleans stay
  # booleans, modes and variants are strings.
  def wire(evaluation)
    {
      "value" => evaluation.value.is_a?(Symbol) ? evaluation.value.to_s : evaluation.value,
      "variant" => evaluation.variant,
      "reason" => evaluation.reason,
      "error_code" => evaluation.error_code,
      "source_env_var" => evaluation.source_env_var
    }
  end
end
