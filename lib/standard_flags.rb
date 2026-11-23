require "active_support"
require "active_support/core_ext/object/blank"

require "standard_flags/version"
require "standard_flags/errors"
require "standard_flags/result"
require "standard_flags/actor"
require "standard_flags/events"
require "standard_flags/reason"
require "standard_flags/evaluation"
require "standard_flags/mode"
require "standard_flags/definition"
require "standard_flags/registry"
require "standard_flags/context"
require "standard_flags/memo"
require "standard_flags/reporting"
require "standard_flags/parser"
require "standard_flags/env_pin"
require "standard_flags/testing"
require "standard_flags/bucket"
require "standard_flags/runtime"
require "standard_flags/resolvers"
require "standard_flags/evaluator"
require "standard_flags/reader"
require "standard_flags/snapshot"
require "standard_flags/sensor"
require "standard_flags/payload"
require "standard_flags/config"
require "standard_flags/notifiers/logger"
require "standard_flags/notifiers/sentry"
require "standard_flags/notifiers/metrics"
require "standard_flags/subscribers"
require "standard_flags/diagnostics"
require "standard_flags/audit_trail"
require "standard_flags/operations"
require "standard_flags/mcp"
require "standard_flags/tooling"
require "standard_flags/health_contribution"
require "standard_flags/engine" if defined?(::Rails::Engine)

# standard_health 0.9+ registers this check by default and lists forbidden
# pins on /diagnostics/env. Runs at require time, before app initializers.
ActiveSupport.on_load(:standard_health, &StandardFlags::HealthContribution::HOOK)

module StandardFlags
  # Loaded on first reference: they need actionpack, activejob (Job and
  # PurgeJob) and standard_health respectively, which the host brings.
  autoload :Controller, "standard_flags/controller"
  autoload :Job, "standard_flags/job"
  autoload :PurgeJob, "standard_flags/purge_job"
  autoload :HealthCheck, "standard_flags/health_check"

  class << self
    # Declares the app's flags, normally in config/flags.rb. Replaces the
    # previous registry, so the file can be reloaded.
    def define(&block)
      builder = Registry::Builder.new
      builder.instance_eval(&block)
      @registry = builder.build
      Memo.clear!
      HealthContribution.refresh!(@registry)
      @registry
    end

    def registry
      @registry ||= Registry.empty
    end

    # Loads `config.registry_path` under `root` when it exists.
    def load_registry!(root = default_root)
      return unless root

      path = File.join(root.to_s, config.registry_path)
      load(path) if File.exist?(path)
    end

    def configure
      yield config
      subscribers.setup!
      config
    end

    def config
      @config ||= Config.new
    end

    def subscribers
      @subscribers ||= Subscribers.new
    end

    # Restores an empty registry and default config. For the gem's own specs
    # and host test harnesses; never needed in app code.
    def reset!
      subscribers.teardown!
      @registry = nil
      @config = nil
      Runtime.reset!
      Testing.reset!
    end

    def reader(for: nil)
      Reader.new(registry, Context.wrap(binding.local_variable_get(:for)))
    end

    def evaluate(key, for: nil)
      reader(for: binding.local_variable_get(:for)).evaluate(key)
    end

    # Same answer as `evaluate`. Experiments will record an exposure on
    # `variant`/`evaluate` and not on `peek`.
    def peek(key, for: nil)
      reader(for: binding.local_variable_get(:for)).peek(key)
    end

    def on?(key, for: nil)
      reader(for: binding.local_variable_get(:for)).on?(key)
    end

    def off?(key, for: nil)
      reader(for: binding.local_variable_get(:for)).off?(key)
    end

    def mode(key, for: nil)
      reader(for: binding.local_variable_get(:for)).mode(key)
    end

    def variant(key, for: nil)
      reader(for: binding.local_variable_get(:for)).variant(key)
    end

    def snapshot(for: nil)
      Snapshot.build(registry, Context.wrap(binding.local_variable_get(:for)))
    end

    def sensor(key, for: nil, report: true, &block)
      raise ArgumentError, "sensor needs a block" unless block

      Sensor.run(reader(for: binding.local_variable_get(:for)), key, report: report, &block)
    end

    def payload(audience, for: nil)
      Payload.build(registry, audience, Context.wrap(binding.local_variable_get(:for)))
    end

    # Reads the runtime memberships of many units in one query and memoises
    # them for the current unit of work, so evaluating a flag for each record
    # in a loop doesn't run a query per record:
    #
    #   StandardFlags.preload(:organization, organizations)
    #   organizations.each { |org| StandardFlags.on?(:new_checkout, for: { organization: org }) }
    #
    # Takes records or keys. A no-op unless runtime rules are on and a unit
    # of work (request, job, executor block) is open.
    def preload(unit, records_or_keys)
      Runtime.preload(unit, records_or_keys)
    end

    def payload_digest(audience, for: nil)
      Payload.digest(payload(audience, for: binding.local_variable_get(:for)))
    end

    private

    def default_root
      ::Rails.root if defined?(::Rails) && ::Rails.respond_to?(:root)
    end
  end
end
