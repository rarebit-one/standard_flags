# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Runtime rules (read path), opt-in.** `config.runtime_rules` (default
  false) and `config.refresh_interval` (default 5 seconds). With runtime rules
  off, behaviour is unchanged and the gem never loads ActiveRecord.
- **Migrations generator.** `bin/rails g standard_flags:migrations`, and
  `standard_flags:install --runtime`, write one migration creating
  `standard_flags_rules`, `standard_flags_cohorts`,
  `standard_flags_memberships` and the single-row `standard_flags_state`, with
  UUID keys when the app generates them. It passes StrongMigrations.
- **Runtime resolver** between the ENV pin and the code default. Draft and
  paused rules serve the code default, stopped rules their stop value, and
  running rules walk deny, allow, cohorts, segments, client conditions,
  percentage and variants, then the fallthrough. `Evaluation#rule_id` names
  the step that decided. A missing unit key returns `TARGETING_KEY_MISSING`;
  an unservable stored value fails only its flag with `PARSE_ERROR`.
- **Process cache** of the rules table: an immutable snapshot refreshed
  lazily on evaluation when the revision moves, no background thread, last
  good snapshot (marked stale) on database errors, code defaults before the
  first load.
- **Memberships** read in one query per unit key per unit of work, skipped
  when no rule could match; `StandardFlags.preload(unit, records_or_keys)`
  reads many in one query and never raises. A failed lookup is remembered
  for the unit of work; its flags skip members and cohorts and carry on with
  reason `ERROR` / `GENERAL`.
- **One rules snapshot per unit of work**, pinned by the first evaluation,
  so a request or job never mixes revisions.
- **Stores.** `StandardFlags::Runtime::ActiveRecordStore` (the default) and
  `MemoryStore` (specs, apps without a database), via `config.runtime_store`.
- **Registry.** `unit ..., key: ->(actor) { ... }` normalises unit keys
  (default `record.id.to_s`, else the value; blank is missing).
  `bucketing: { version: 1 | 2, salt: }` on flags, modes and experiments.
- **`config.segment_resolver`** answers segment conditions.
- **Test helpers** `with_rule`, `with_members` and `with_cohort` (and
  `StandardFlags::Testing.rule/members/cohort`), backed by `MemoryStore` and
  reset after each example.
- **Health and diagnostics.** The health check fails when runtime rules are
  on and their tables are missing. It warns when the store can't be reached,
  on a stale snapshot, when prepared statements are off (unit keys would be
  inlined into SQL text), and on rules for undeclared or tombstoned keys.
  Diagnostics and `flags:list` show each rule's status and the snapshot's
  revision and age.
- **Privacy.** With runtime rules on, `unit_key` is added to
  `ActiveRecord::Base.filter_attributes` so SQL logs filter it; `Membership`
  hides it from `inspect` and `pp`; read errors are reported by class only.
- **standard_health contributions.** On standard_health 0.9+, the gem
  contributes its check (`:standard_flags`, non-critical) to
  `register_default_checks` and declares the pins of `forbidden_in:` flags in
  the env audit. Registering `StandardFlags::HealthCheck` by hand still works.
- **`config.error_reporter`** = `->(error, context) { ... }` replaces
  `Rails.error` for every report the gem makes, falling back to `Rails.error`
  if it raises.
- **Notifications** `runtime_refresh`, `runtime_stale`, `rule_invalid` and
  `targeting_key_missing` (`.standard_flags`), with Logger lines.
- **Conformance** fixtures for runtime rules
  (`spec/fixtures/conformance/runtime/`), and a Postgres CI job that runs the
  database specs, including `Bucket.v2` against `Bucket.sql_v2`.
- **`legacy_parser: :exact`** (with `legacy_true:`, default `%w[on]`) reads
  legacy `env:` names the way an exact `ENV["X"] == "on"` reader did: on/off
  kinds are on only for a `legacy_true:` value and pinned off by any other
  value, including a set-but-blank one (an unset variable still falls
  through; inverted names keep blank as unset); modes and experiments match
  a value exactly and treat blank as unset. The
  canonical `STANDARD_FLAGS_<KEY>` pin stays strict. Conformance fixtures in
  `legacy_exact.json`.
- **Mode lifecycle.** `mode` accepts `remove_by:` with `final:` (one of its
  values), or `permanent: true`, with the same rules as `flag`. Stale modes
  appear in `flags:stale`, Diagnostics and the health check's warnings.
- **`StandardFlags.sensor(..., report: false)`** swallows an observe error in
  sensor mode without reporting it; the notification still carries the error
  class. The default still reports.

### Changed

- The manifest's `permanent` key is now on entries of kind `mode` as well as
  `flag`. Regenerate a committed manifest after upgrading.

### Fixed

- **Overrides set in an `around` hook were discarded.** `standard_flags/rspec`
  reset overrides in `config.before`, which runs inside `example.run`, so
  `around { |ex| with_flag(:x, true) { ex.run } }` read the code default. The
  reset now runs in a config-level `around` hook, outside every group-level
  one, and overrides set before an example starts fail it with a clear error
  instead of being dropped. `flags:` metadata and `before` hooks work as
  before. `StandardFlags::RSpecSupport.install(config)` wires the helpers into
  a custom configuration.

## [0.1.0] - 2026-11-22

### Added

First release (0.1.0, Phase 1: registry, ENV layer and evaluation API; no
database tables).

- **Registry.** `StandardFlags.define` in `config/flags.rb`, loaded on boot
  and on every code reload. Kinds: `flag`, `kill_switch`, `mode` (presets
  `:sensor`, `:cutover`, `:shadow`, or `values:`), `experiment`, `compat`,
  and `tombstone`. Attributes: `owner:`, `description:`, `default:` (scalar
  or per environment), `env:`, `inverted:`, `forbidden_in:`, `fail:`,
  `expose:`, `unit:`, and `remove_by:` / `final:` (required on `flag`).
  `env_resolver` and `unit` declarations. Define-time validation raises
  `StandardFlags::DefinitionError`, including for a reused tombstoned key.
- **Resolution** in a fixed order: test override, `forbidden_in` guard, ENV
  pin (`STANDARD_FLAGS_<KEY>`, then legacy `env:` names), code default. One
  strict parser for every ENV value; rejected pins are ignored and reported
  once per process. Per-flag error isolation returns the `fail:` value with
  reason `ERROR`.
- **OpenFeature-shaped results.** `StandardFlags::Evaluation` with `value`,
  `variant`, `reason`, `error_code`, `rule_id` and `source_env_var`.
- **Read API.** `on?`, `off?`, `mode` (a `StandardFlags::Mode` with one
  predicate per value), `variant`, `evaluate`, `peek`, `snapshot`, and
  `StandardFlags::Context`. Memoised per unit of work through the Rails
  executor.
- **Sensor helper** `StandardFlags.sensor` for `preset: :sensor` modes.
- **Guards.** `StandardFlags::Controller` (`requires_flag`, JSON:API
  `feature_disabled` error, `standard_flags_payload`) and
  `StandardFlags::Job` (`requires_flag ..., retry:`, `StandardFlags::Disabled`).
- **Client payload.** `StandardFlags.payload(audience)` and `payload_digest`
  for exposed flags only, keyed by wire name.
- **Bucketing contract.** `StandardFlags::Bucket.v1`, `v2` and the Postgres
  twin `sql_v2`, with fixed test vectors. Not yet used by evaluation.
- **Conformance fixtures** in `spec/fixtures/conformance/` for evaluators in
  other languages.
- **Rake tasks.** `flags:list`, `flags:stale`, `flags:refs`,
  `standard_flags:manifest`, `standard_flags:typescript`.
- **Notifications** `evaluate`, `sensor`, `pin_rejected`, `forbidden` and
  `legacy_env` (`*.standard_flags`), with Logger, Metrics and opt-in Sentry
  subscribers.
- **Health and diagnostics.** Opt-in `StandardFlags::HealthCheck` for
  standard_health and `StandardFlags::Diagnostics.report`.
- **Install generator** `rails g standard_flags:install`.
- **RSpec helpers** (`require "standard_flags/rspec"`): `with_flag`,
  `with_mode`, `with_variant`, `flags:` metadata, automatic reset, strict
  unknown keys.
- **Permanent flags.** `flag ..., permanent: true` declares a standing
  switch (an environment permission, say) with no `remove_by:` or `final:`
  (both rejected when permanent). It may default off or on, is never stale,
  and shows as permanent in `flags:list`, `Diagnostics.report` and the
  manifest (`"permanent"` on entries of kind `flag`). Conformance fixture
  `permanent_flags.json`.
- **Per-guard controller responder.** `requires_flag :key, with:` takes a
  callable `(controller, denial)` or a Symbol naming a controller method
  `(denial)`, and overrides `config.controller_responder` for that guard
  only.
- **Job error class.** `StandardFlags::Job` `requires_flag :key, error:`
  raises an exception class, or what a proc returns, when the flag is off,
  so jobs that already `retry_on` their own error can adopt the guard.
  `error:` always raises: `retry: true` alongside it is redundant and
  `retry: false` is rejected.

### Fixed

- Rake tasks are defined once. The engine no longer loads
  `lib/tasks/standard_flags.rake` itself on top of Rails::Engine's own
  `lib/tasks` loading, which gave every task two actions (`flags:list`
  printed twice).

### Documentation

- README and the resolution-order docs state that test overrides (layer 1)
  beat `forbidden_in` guards (layer 2), so a spec proving a guard must use a
  real ENV pin rather than `with_flag`, with the pattern.
