# standard_flags

Feature flags, kill switches, staged modes and experiments for Rails apps.

StandardFlags is a small Rails engine. Every flag is declared once, in code,
with an owner. Values come from a fixed, documented chain: test overrides,
guards, environment pins, then per-environment code defaults. Results have
the [OpenFeature](https://openfeature.dev) shape (value, variant, reason,
error code), so "why is this on?" is always a one-line answer.

This is version 0.1.0 (Phase 1): registry, ENV layer and evaluation API. It
needs no database tables. See [Roadmap](#roadmap).

- [Install](#install)
- [Declaring flags](#declaring-flags)
- [Reading flags](#reading-flags)
- [How a value is decided](#how-a-value-is-decided)
- [Environment variables](#environment-variables)
- [Sensor rollouts](#sensor-rollouts)
- [Controller and job guards](#controller-and-job-guards)
- [Client payload](#client-payload)
- [Rake tasks](#rake-tasks)
- [Observability](#observability)
- [Health check and diagnostics](#health-check-and-diagnostics)
- [Testing](#testing)
- [Conformance suite](#conformance-suite)
- [Bucketing](#bucketing)
- [Roadmap](#roadmap)

## Install

```ruby
# Gemfile
gem "standard_flags"
```

```bash
bundle install
bin/rails g standard_flags:install
```

The generator writes `config/initializers/standard_flags.rb` (runtime
settings, all commented) and `config/flags.rb` (the registry, with one
commented example per kind). The engine loads `config/flags.rb` on boot and
on every code reload.

Requires Ruby 4.0+ and Rails 8.1+.

## Declaring flags

```ruby
# config/flags.rb
StandardFlags.define do
  # The logical environment. Pass your own when staging boots with
  # RAILS_ENV=production. Defaults to Rails.env.
  env_resolver -> { ENV.fetch("APP_ENVIRONMENT", Rails.env) }

  unit :account, from: ->(ctx) { ctx.account }

  flag :new_checkout,
       owner: "payments",
       description: "Rebuilt checkout flow",
       remove_by: "2027-03-01",
       final: true,
       unit: :account,
       default: { staging: true, production: false },
       expose: { web: :newCheckout }

  kill_switch :ai_assistant,
              owner: "assistant",
              env: "ACME_LEGACY_DISABLED", inverted: true,
              expose: { web: :assistant, mobile: :assistant }

  mode :strict_gates, owner: "platform", preset: :sensor
  mode :billing_cutover, owner: "billing", values: %i[off shadow enforce]

  experiment :home_hero, owner: "growth", variants: %w[control savings privacy]

  compat :legacy_form_auth, owner: "identity"

  flag :demo_data, owner: "platform", remove_by: "2027-06-01", final: false,
       forbidden_in: :production

  tombstone :manual_entry, removed: "2026-12-01"
end
```

### Kinds

| Kind | Values | Default | Use for |
|------|--------|---------|---------|
| `flag` | on / off | off | Temporary release flags. `remove_by:` and `final:` are required. |
| `kill_switch` | on / off | on, fails open | Permanent switches that turn a feature off in an emergency. |
| `mode` | declared values | first value | Staged rollouts. Presets: `:sensor` (off/sensor/on), `:cutover` (off/allowlist/all), `:shadow` (off/shadow/enforce); or `values:`. |
| `experiment` | declared variants | first variant | Experiments. In 0.1.0 an experiment always resolves to its first variant (list `control` first) unless pinned by ENV. |
| `compat` | on / off | on | Compatibility shims that stay on until they are removed. |
| `tombstone` | — | — | A removed key. It can never be declared again. |

### Attributes

| Attribute | Meaning |
|-----------|---------|
| `owner:` | Required on every kind. Who to ask about the flag. |
| `description:` | What it does. |
| `default:` | A value, or `{ env_name => value }`. Environments not listed get the kind's default. |
| `env:` | Legacy environment variable name(s) still honoured. See [Environment variables](#environment-variables). |
| `inverted:` | The legacy name is a `*_DISABLED` variable: legacy on means flag off. |
| `forbidden_in:` | Environment name(s) where the flag is forced off. A pin that tries to turn it on is reported once per process. |
| `fail:` | The value returned if evaluation raises. Kill switches default to on. |
| `expose:` | `{ audience => wire_name }`, or a list of audiences to use the key. Default: not exposed. |
| `unit:` | The unit the flag targets. Carried in the context now; used by targeting later. |
| `remove_by:`, `final:` | On `flag`: the date it should be gone, and the value it settles on. |

The registry is validated when it loads. `StandardFlags::DefinitionError` is
raised for a reused tombstoned key, a missing owner, a `flag` without
`remove_by:`/`final:`, a default outside a mode's values, the same wire name
used twice for one audience, an undeclared unit, or any unknown attribute.

**Keys are immutable and never reused.** An old key brought back for new
work can wake up code that was meant to be dead. Remove a flag by replacing
its declaration with a `tombstone`.

## Reading flags

```ruby
StandardFlags.on?(:new_checkout, for: account)        # => true
StandardFlags.off?(:new_checkout, for: account)       # => false

mode = StandardFlags.mode(:strict_gates)              # => #<StandardFlags::Mode :sensor>
mode.sensor?                                          # => true
mode.at_least?(:sensor)                               # => true
mode.enforce?                                         # NoMethodError: not a declared value

StandardFlags.variant(:home_hero, for: visitor)       # => "control"

StandardFlags.evaluate(:ai_assistant)
# => #<data StandardFlags::Evaluation key=:ai_assistant, value=false, variant="off",
#      reason="KILL_SWITCH", error_code=nil, rule_id=nil, source_env_var="ACME_LEGACY_DISABLED">

StandardFlags.peek(:home_hero)                        # same as evaluate

snap = StandardFlags.snapshot(for: account)           # every flag, evaluated once, frozen
rows.each { |row| import(row) if snap.on?(:new_checkout) }
```

`for:` takes a single target, a hash of actors per unit
(`{ account: a, organization: o }`), or a `StandardFlags::Context`, which can
also carry an environment override and client attributes
(`platform`, `version`, `build`).

### Results

`StandardFlags::Evaluation` is immutable:

- `value`: true/false for on/off kinds, a Symbol for modes, a String for experiments.
- `variant`: the value as a string (`"on"`/`"off"` for booleans).
- `reason`: `STATIC`, `DEFAULT`, `TARGETING_MATCH`, `SPLIT`, `DISABLED`, `ERROR`, plus `ENV_PIN` and `KILL_SWITCH`.
- `error_code`: the OpenFeature set (`FLAG_NOT_FOUND`, `PARSE_ERROR`, `TYPE_MISMATCH`, `TARGETING_KEY_MISSING`, `INVALID_CONTEXT`, `PROVIDER_NOT_READY`, `PROVIDER_FATAL`, `GENERAL`), only when the reason is `ERROR`.
- `rule_id`: the matching runtime rule. Always nil in 0.1.0.
- `source_env_var`: the name of the variable that decided the value. Never its contents.

### Errors and strictness

- **Per-flag isolation.** Anything raised while evaluating one flag returns
  that flag's `fail:` value with reason `ERROR` and error code `GENERAL`,
  reports through `Rails.error` (handled), and leaves every other flag
  alone. The read path never raises in production.
- **Unknown keys** raise `StandardFlags::UnknownFlag` when `config.strict`
  is on, which is the default everywhere except a production Rails process.
  In production the read fails safe: `on?` is false and `evaluate` returns
  reason `ERROR` with `FLAG_NOT_FOUND`.
- **Kind mismatches** (`on?` on a mode, say) raise
  `StandardFlags::TypeMismatch` when strict and read as off otherwise.

### Memoisation

Evaluations are memoised per unit of work through the Rails executor, not
Rack middleware, so requests, jobs, mailers and console reloads all get a
consistent answer within one unit and a fresh read of ENV in the next.
Outside an executor run nothing is memoised.

## How a value is decided

Each evaluation walks these layers in order and stops at the first one that
answers. Gates are never OR'd together.

1. **Test override.** `with_flag(:x, true)`. Exists only in tests. Reason `STATIC`.
2. **Guard.** `forbidden_in:` forces the off value. Reason `DISABLED`.
3. **ENV pin.** `STANDARD_FLAGS_<KEY>`, then legacy `env:` names. Reason
   `ENV_PIN`, or `KILL_SWITCH` when a kill switch is pinned off.
4. **Code default** for the current environment. Reason `DEFAULT`.

Runtime rules arrive between 3 and 4, so an ENV pin keeps beating any
database rule and keeps working with the database down.

## Environment variables

Every flag can be pinned with its canonical variable, `STANDARD_FLAGS_<KEY>`
(the key upcased): `STANDARD_FLAGS_NEW_CHECKOUT=on`.

One strict parser reads every value, trimmed and case-insensitive:

- on/off kinds: `on`/`off`, `true`/`false`, `1`/`0`, `yes`/`no`;
- modes: a declared value; experiments: a declared variant.

Anything else is ignored and reported once per process per variable, through
`Rails.error.report(handled: true)` and a `pin_rejected.standard_flags`
notification. A blank value counts as unset.

### Legacy names

To adopt the gem without renaming deployed variables, declare the old name:

```ruby
kill_switch :ai_assistant, owner: "assistant", env: "ACME_LEGACY_DISABLED", inverted: true
```

- `env:` takes one name or several; the first that parses wins, in order.
- The canonical name wins over every legacy name. When both are set, the
  legacy one is reported as shadowed.
- `inverted: true` flips legacy values only: `ACME_LEGACY_DISABLED=true`
  means the kill switch is off. The canonical variable is never inverted.
- Using a legacy name emits `legacy_env.standard_flags` once per process,
  and the health check reports it as deprecated. Rename on your own schedule.

Moving from hand-written predicates changes one thing on purpose: values the
strict parser doesn't accept are ignored. A legacy `ENV["X_DISABLED"].present?`
check treated `X_DISABLED=false` as disabled; with `inverted: true` it now
means enabled. Call that out when migrating a flag.

## Sensor rollouts

For a mode declared with `preset: :sensor`:

```ruby
StandardFlags.sensor(:strict_gates, for: run) do |s|
  s.observe { Gates.evaluate(run) }            # runs in sensor and on
  s.enforce { |verdict| hold!(run, verdict) }  # runs only in on
end
```

- **off**: neither block runs; returns nil.
- **sensor**: `observe` runs and its result goes into a
  `sensor.standard_flags` notification; returns the observation. An
  exception in `observe` is reported and swallowed, since sensor mode must
  not change behaviour.
- **on**: `observe` runs, the notification fires, then `enforce` receives the
  observation; returns `enforce`'s result. Exceptions propagate.

## Controller and job guards

```ruby
class ApplicationController < ActionController::Base
  include StandardFlags::Controller

  private

  # Who flags are evaluated for in this controller. Defaults to nil.
  def standard_flags_context = Current.account
end

class ReportsController < ApplicationController
  requires_flag :new_reports, except: :index
  requires_flag :legacy_export, error: :not_found   # keep an existing 404 contract
  requires_flag :ai_assistant, status: 503
end
```

A JSON request for a disabled flag gets one JSON:API error:

```json
{"errors":[{"status":"403","code":"feature_disabled","meta":{"feature":"reportsV2"}}]}
```

`meta.feature` is the flag's wire name for `config.default_audience`
(`:web`), or the key when it has none. `error: :not_found` answers 404 with
no meta. Other formats get the bare status. A mode counts as enabled once it
is past its first value. Replace the response with
`config.controller_responder = ->(controller, denial) { ... }`.

```ruby
class ReplyJob < ApplicationJob
  include StandardFlags::Job

  requires_flag :ai_assistant, retry: true, for: -> { arguments.first }
  retry_on StandardFlags::Disabled, wait: 5.minutes, attempts: 12
end
```

With `retry: true` a disabled flag raises `StandardFlags::Disabled` so
`retry_on` can reschedule. Without it the job is discarded unrun.

## Client payload

Clients see evaluated values only, never rules or the names of flags they
aren't meant to see:

```ruby
StandardFlags.payload(:web, for: account)          # => { "assistant" => true, "newCheckout" => false }
StandardFlags.payload_digest(:web, for: account)   # => "9f3c…" (stable hash of the result)
```

Only flags with `expose:` for that audience appear, keyed by wire name. Wire
names are separate from keys, so renaming or removing a flag doesn't break a
shipped client. Booleans stay booleans; modes and variants are strings. The
digest hashes the evaluated result, so it changes whenever the answers do,
which makes it a safe ETag.

With Inertia:

```ruby
class ApplicationController < ActionController::Base
  include StandardFlags::Controller
  inertia_share features: -> { standard_flags_payload(:web) }
end
```

## Rake tasks

| Task | What it does |
|------|--------------|
| `bin/rails flags:list` | Every flag with its value, reason, deciding env var and remove_by. |
| `bin/rails flags:stale` | Flags past `remove_by`, with the `final:` value to keep. |
| `bin/rails flags:refs` | Scans `config.refs_paths` (default `app lib config`) for `on?(:k`, `off?(:k`, `mode(:k`, `variant(:k`, `evaluate(:k`, `requires_flag :k` and string keys. Exits non-zero for undeclared or tombstoned keys; warns for declared flags nothing reads. Run it in CI. |
| `bin/rails standard_flags:manifest` | Writes `config/flags.manifest.json`: keys, wire names, kinds, values, audiences and defaults, deterministically. Commit it. |
| `bin/rails standard_flags:typescript` | Writes a `.d.ts` with a `Features` interface per audience (`WebFeatures`, `MobileFeatures`, …) keyed by wire name. |

## Observability

`ActiveSupport::Notifications` events:

| Event | When |
|-------|------|
| `evaluate.standard_flags` | Sampled evaluations (`config.evaluate_sample_rate`, default 0). |
| `sensor.standard_flags` | A sensor-mode observation. |
| `pin_rejected.standard_flags` | An ENV pin that didn't parse. |
| `forbidden.standard_flags` | A `forbidden_in` flag pinned on where it's forbidden. |
| `legacy_env.standard_flags` | A legacy env name in use. |

Built-in subscribers: **Logger** (always), **Metrics** (`Sentry::Metrics`
counters when sentry-ruby is loaded) and **Sentry** (handled warnings for
rejected and forbidden pins). Sentry is off by default because those pins
already go to `Rails.error`; enable it only when `Rails.error` isn't wired to
your error tracker. Add your own with
`config.add_notifier(->(name, payload) { ... })`.

## Health check and diagnostics

With [standard_health](https://github.com/rarebit-one/standard_health):

```ruby
StandardHealth.configure do |c|
  c.register_check :flags, StandardFlags::HealthCheck
end
```

The check fails when a `forbidden_in` flag is pinned on, and warns on
unparseable pins, legacy names in use, flags past `remove_by`, and
`STANDARD_FLAGS_*` variables that match no flag. standard_health has no
warning status, so warnings ride on the row (`warnings:`) and the check stays
`:ok`; pass `warn_as: :fail` to let them degrade the tier. It is non-critical
by default. There is no dependency on standard_health unless you reference
the check.

`StandardFlags::Diagnostics.report` returns the same picture as a hash for a
diagnostics page: each flag's value, reason and deciding variable, plus
forbidden, rejected, legacy and unknown pins and stale flags. It contains
variable names only, never raw environment values.

## Testing

```ruby
# spec/rails_helper.rb
require "standard_flags/rspec"
```

```ruby
with_flag(:new_checkout, true) { ... }          # for the block
with_flag(:new_checkout, true)                  # for the rest of the example
with_mode(:strict_gates, :sensor) { ... }
with_variant(:home_hero, "savings") { ... }

it "shows the new checkout", flags: { new_checkout: true } do
  ...
end
```

Overrides are the first evaluation layer, so they beat ENV pins and defaults
without touching `ENV`. Unknown keys, wrong kinds and undeclared values
raise; unknown keys raise on read too (strict mode); everything resets after
each example.

## Conformance suite

`spec/fixtures/conformance/*.json` holds the evaluation contract as data.
Each file has a registry snippet and cases: environment variables and a
context in, the expected value, variant, reason, error code and deciding
variable out. `bucket_vectors.json` pins test vectors for every bucketing
version. The Ruby suite runs every case. Evaluators in other languages (a
Kotlin or TypeScript client, say) run the same files, so they cannot drift
from the server on what a flag evaluates to.

## Bucketing

`StandardFlags::Bucket` holds the bucketing contract for percentage rollouts
and experiments. It is not used by evaluation yet.

```ruby
StandardFlags::Bucket.v1(salt, unit_key)              # SHA-256("salt:unit_key")[0, 15] hex % 10_000
StandardFlags::Bucket.v2(:rollout, salt, unit_key)    # SHA-256("v2|rollout|salt|unit_key") ...
StandardFlags::Bucket.v2(:variant, salt, unit_key)    # a separate input for variant choice
StandardFlags::Bucket.sql_v2(column: "devices.id")    # the Postgres twin; bind :salt
```

Buckets are basis points (0–9,999). A nil or blank unit key returns nil (the
caller maps it to `TARGETING_KEY_MISSING`), never a random bucket. These
functions are permanent: a new algorithm gets a new version and existing
flags keep theirs.

## Roadmap

Phase 2 adds runtime rules stored in the database (changes without a
redeploy, allow and deny lists, cohorts, sticky percentage rollouts with
per-flag salts), audited write operations and an admin generator. Phase 3
adds client delivery: an OpenFeature remote-evaluation (OFREP) endpoint,
client version targeting, a minimum-version endpoint and the manifest
contract checked in client CI. Phase 4 adds experiment exposure tracking and
staged rollout plans with automatic halts.

## License

MIT. See [LICENSE](LICENSE).
