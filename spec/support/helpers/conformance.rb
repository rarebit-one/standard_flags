require "date"
require "json"
require "time"

# Builds a registry from a conformance fixture's "registry" block. Other
# evaluators (Kotlin, TypeScript) implement the same mapping.
module ConformanceRegistry
  # The suite ships in the gem, at the top level, so other runners can read
  # it from an installed copy.
  ROOT = File.expand_path("../../../conformance", __dir__)

  module_function

  # A path (or glob pattern) under conformance/.
  def path(relative)
    File.join(ROOT, relative)
  end

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

  # The registry of a fixture with units (unit name => the context's key for
  # it) and tombstones that may serve static wires.
  def define_with_units(spec)
    StandardFlags.define do
      Array(spec["units"]).each { |name| unit name.to_sym, from: ->(ctx) { ctx.actor(name) } }
      Array(spec["flags"]).each do |flag|
        attributes = flag.except("kind", "key").transform_keys(&:to_sym)
        public_send(flag.fetch("kind"), flag.fetch("key"), **attributes)
      end
      Array(spec["tombstones"]).each { |t| tombstone(t.fetch("key"), **t.except("key").transform_keys(&:to_sym)) }
    end
  end

  # A MemoryStore holding a case's rules, cohorts and memberships.
  def store(example)
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

  # Runs one delivery.json case: the OFREP body the server sends.
  def deliver(fixture, example)
    StandardFlags::Testing.deactivate!
    define_with_units(fixture.fetch("registry"))
    StandardFlags.config.env_source = example.fetch("env_vars", {})
    StandardFlags.config.runtime_rules = true
    StandardFlags.config.runtime_store = store(example)
    context = example.fetch("context", {})
    today = Date.iso8601(example.fetch("today") { fixture.fetch("today") })
    StandardFlags::Delivery.build(
      example.fetch("audience"),
      StandardFlags::Context.new(env: example.fetch("environment") { fixture.fetch("environment") },
                                 actors: context.fetch("units", {}), client: context.fetch("client", {})),
      today: today
    ).to_h
  end

  # Evaluation values in the wire shape the fixtures use: booleans stay
  # booleans, modes and variants are strings.
  CLIENT_HEADERS = { "platform" => "X-Client-Platform", "version" => "X-Client-Version", "build" => "X-Client-Build" }.freeze

  # A client_status case's payload: the fixture's platforms and clients
  # (with the case's store lookups), the case's headers, today and ENV pins.
  def client_status(fixture, example)
    StandardFlags.config.client_platforms = fixture.fetch("client_platforms")
    lookups = example.fetch("store_lookup", {})
    clients = fixture.fetch("clients")
    StandardFlags.define do
      clients.each do |entry|
        attributes = entry.except("name", "grace_days").transform_keys(&:to_sym)
        attributes[:grace] = entry["grace_days"] if entry.key?("grace_days")
        attributes[:store_lookup] = ->(_app) { lookups[entry["name"]] } if lookups.key?(entry["name"])
        client entry.fetch("name"), **attributes
      end
    end
    headers = example.fetch("client").to_h { |field, value| [ CLIENT_HEADERS.fetch(field), value.to_s ] }
    StandardFlags::ClientStatus.for(StandardFlags::Client.from_headers(headers), group: example["group"]&.to_sym,
                                    today: Date.iso8601(example.fetch("today") { fixture.fetch("today") }),
                                    env: example.fetch("env_vars", {})).to_h
  end

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
