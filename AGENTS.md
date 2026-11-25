# AGENTS.md - AI Agent Guide for StandardFlags

StandardFlags is a Rails engine for feature flags, kill switches, staged
modes and experiments: a typed registry in code, one strict ENV parser,
OpenFeature-shaped evaluation results, a sensor helper, controller and job
guards, a client capability payload, and test helpers. See README.md for the
user-facing contract.

## Public repo: no private content

This repository is public. Everything in it (code, comments, specs,
fixtures, README, CHANGELOG, commit messages, issues and PRs) must be
generic.

- Never name private applications, clients, companies, people, internal
  hosts, private paths, audit findings or incidents. The only organisation
  named is `rarebit-one`, in repository URLs.
- Examples use neutral names: `:new_checkout`, `:ai_assistant`,
  `:strict_gates`, `:home_hero`, `ACME_LEGACY_DISABLED`.
- Explain why a rule exists in general terms ("an old key can wake up dead
  code"), not by pointing at the system where it happened.
- Before pushing, grep the diff for anything that looks like a private name.

## Quick Reference

```bash
bundle exec rspec                      # tests (single process)
bundle exec rspec spec/conformance_spec.rb
bundle exec rubocop                    # lint
bundle exec rubocop -A                 # auto-fix
bundle exec brakeman --no-pager --force
bundle exec bundler-audit --update
gem build standard_flags.gemspec
```

## Project Structure

```
lib/standard_flags.rb               # Facade: define, configure, on?/mode/variant/evaluate/snapshot/sensor/payload
lib/standard_flags/
├── definition.rb                   # One declared flag + per-declaration validation
├── registry.rb                     # Immutable registry + Builder DSL + cross-flag validation
├── context.rb                      # Actors per unit, env override, client attributes
├── client.rb                       # Calling client (platform, version, build); X-Client-* header parsing
├── client_app.rb                   # Client registry entry (`client` in config/flags.rb), ENV pins, grace
├── client_status.rb + client_status/controller.rb
│                                   # Upgrade status (ok/recommended/required/unknown); GET /client/status mixin
├── stores.rb + stores/app_store.rb # Per-client store lookups; the App Store adapter (background refresh, autoloaded)
├── semantic_version.rb             # StandardFlags::Version: SemVer 2.0 + shorthands, precedence
├── version_range.rb                # VersionRange / BuildRange: portable comparator syntax; RubyGems ranges read
├── parser.rb                       # The one strict ENV parser
├── env_pin.rb                      # Side-effect-free scan of canonical + legacy variables
├── resolvers.rb                    # The evaluation chain (override, guard, pin, default)
├── evaluator.rb                    # Memo, per-flag error isolation, unknown keys
├── reader.rb / snapshot.rb         # Typed reads; frozen snapshot
├── evaluation.rb / reason.rb       # OpenFeature-shaped result, reasons, error codes
├── mode.rb / sensor.rb             # Mode value object; sensor helper
├── payload.rb / bucket.rb          # Flat client payload + digest; bucketing contract
├── delivery.rb / audience.rb       # OFREP entries + ETag for an audience; config.audiences
├── ofrep.rb + ofrep/controller.rb  # OFREP request parsing; the endpoint mixin (autoloaded, actionpack)
├── memo.rb                         # Per-unit-of-work memo (executor hook)
├── reporting.rb                    # Rails.error + notifications, once per process
├── testing.rb / rspec.rb           # Test overrides; RSpec helpers for hosts
├── controller.rb / job.rb          # requires_flag and requires_client_version guards (autoloaded)
├── diagnostics.rb / health_check.rb# Diagnostics hash; opt-in standard_health check
├── runtime.rb + runtime/            # Runtime rules: stores, cache, resolver, evaluation and compat trackers
├── operations.rb + operations/     # The write path: audited operations, validation, audit, restore
├── mcp.rb + mcp/                   # Operator tools (list/get/write flags, members, cohorts); no MCP framework;
│                                   #   mcp/gating.rb gates an app's own tools on flags
├── audit_trail.rb                  # Reads write-path history back from standard_audit's audit_logs
├── result.rb / actor.rb / events.rb# Operation results, system actors, published event names
├── purge_job.rb                    # Membership purge (autoloaded; needs activejob)
├── tooling.rb + tooling/           # list / stale / refs / manifest / typescript / show / changes
├── notifiers/                      # Logger, Sentry, Metrics subscribers
└── engine.rb                       # Executor hook, registry loading, subscribers, rake tasks
lib/tasks/standard_flags.rake
lib/generators/standard_flags/install/    # install, migrations, admin (controller, routes, Inertia pages)
conformance/                        # Shipped cross-language fixtures, tagged scope server|wire;
                                    #   schema/fixture.schema.json, README.md; wire/ and versions/version_ranges.json
                                    #   are what clients run; versions/legacy_ranges.json and
                                    #   upgrade/client_status_server.json are Ruby-only
spec/fixtures/ofrep/openapi.yaml    # Vendored OFREP OpenAPI document (responses validated against it)
```

## Key Rules

- **The evaluation order is a contract.** Test override, guard, ENV pin,
  runtime rule, code default. Never OR gates together.
- **The read path never raises in production.** Per-flag errors return the
  flag's `fail:` value with reason ERROR; reporting and notifications are
  wrapped so a broken subscriber can't break a read.
- **Never log or report raw env values.** Variable names only.
- **Bucketing functions are permanent.** Change behaviour only by adding a
  new version; extend `bucket_vectors.json`, never edit existing vectors.
- **Conformance fixtures are the cross-language contract.** A behaviour
  change to evaluation needs a fixture case; keep fixtures generic.
- **Keys are immutable and never reused.** Tombstones enforce it.
- **Only operations write runtime rules.** Every change goes through
  `StandardFlags::Operations` (authorise, refuse pins, lock, validate, bump
  the revision, audit). Validate on write, never on read.
- **Unit keys never leave the memberships table.** No unit key in a Result,
  an audit row, a notification, a log line or an error report; membership
  changes record the unit, the value and counts. Store errors carry only the
  error class. Operator surfaces (MCP tools, the admin page) mask them
  (`•••4567`); only an audited reveal shows them.

## Testing

- RSpec, single process. `spec/support/dummy_app.rb` boots a minimal Rails
  app once, so the engine's executor hook, registry loading and rake tasks
  run for real.
- `spec_helper.rb` resets the registry, config and report memory before
  every example and points `env_source` at an empty hash, so no spec touches
  the real `ENV`.
- A `registry:` metadata proc defines the registry before `flags:` metadata
  is applied, mirroring a host app whose registry loads at boot.
