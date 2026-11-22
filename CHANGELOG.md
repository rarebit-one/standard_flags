# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
