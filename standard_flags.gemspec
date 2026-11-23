require_relative "lib/standard_flags/version"

Gem::Specification.new do |spec|
  spec.name        = "standard_flags"
  spec.version     = StandardFlags::VERSION
  spec.authors     = [ "Rarebit One" ]
  spec.homepage    = "https://github.com/rarebit-one/standard_flags"
  spec.summary     = "Feature flags, kill switches, staged modes and experiments for Rails apps."
  spec.description = "StandardFlags is a Rails engine with a typed flag registry in code, one strict ENV parser, " \
                     "OpenFeature-shaped evaluation results, a sensor helper for staged rollouts, controller and " \
                     "job guards, a client capability payload, and test helpers."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rarebit-one/standard_flags"
  spec.metadata["changelog_uri"] = "https://github.com/rarebit-one/standard_flags/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rarebit-one/standard_flags/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["lib/**/*", "LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.required_ruby_version = ">= 4.0"

  spec.add_dependency "railties", ">= 8.1"
  spec.add_dependency "activesupport", ">= 8.1"
  # Deliberately NOT declared, because they are only ever loaded by the thing
  # that needs them and so are always present when they're loaded:
  #   actionpack     — StandardFlags::Controller is autoloaded on first reference
  #                    from a host controller.
  #   activejob      — StandardFlags::Job is autoloaded on first reference from a
  #                    host job.
  #   activerecord   — the runtime-rule store and its models are required only
  #                    when a host sets config.runtime_rules = true (and
  #                    configures no other store); with it off, nothing in the
  #                    gem loads ActiveRecord.
  #   pg             — runtime rules are Postgres-only (jsonb), through the
  #                    host's own adapter.
  #   openfeature-sdk — StandardFlags::OpenFeature::Provider loads only when a
  #                    host requires "standard_flags/open_feature", which raises
  #                    a LoadError naming the gem when it is missing.
  #   sentry-ruby    — the Sentry and Metrics subscribers no-op without it.
  #   standard_health — StandardFlags::HealthCheck is only defined when it is,
  #                    and the 0.9+ contribution hook only runs when it loads.
  #   standard_audit — operations write their audit rows through it when the
  #                    host has loaded it, and only publish events otherwise.

  spec.add_development_dependency "brakeman"
  spec.add_development_dependency "bundler-audit"
  spec.add_development_dependency "simplecov"
end
