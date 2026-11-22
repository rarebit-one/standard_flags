# standard_flags

Feature flags, kill switches, staged modes and experiments for Rails apps.

StandardFlags is a small Rails engine. Every flag is declared once, in code,
with an owner. Values come from a fixed, documented chain: test overrides,
guards, environment pins, then per-environment code defaults. Results have
the [OpenFeature](https://openfeature.dev) shape (value, variant, reason,
error code), so "why is this on?" is always a one-line answer.

This is version 0.1.0 (Phase 1): registry, ENV layer and evaluation API. It
needs no database tables. Unreleased on `main`: opt-in
[runtime rules](#runtime-rules) stored in the app's own database (the read
path; the audited write operations come next). See [Roadmap](#roadmap).

- [Install](#install)
- [Declaring flags](#declaring-flags)
- [Reading flags](#reading-flags)
- [How a value is decided](#how-a-value-is-decided)
- [Runtime rules](#runtime-rules)
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
  unit :phone, from: ->(ctx) { ctx.phone }, key: ->(phone) { phone.to_s.delete("^0-9+") }

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

  flag :demo_pages, owner: "platform", permanent: true,
       default: { development: true, staging: true }, forbidden_in: :production

  tombstone :manual_entry, removed: "2026-12-01"
end
```

### Kinds

| Kind | Values | Default | Use for |
|------|--------|---------|---------|
| `flag` | on / off | off | Temporary release flags: `remove_by:` and `final:` are required. With `permanent: true`, a standing switch instead (see below). |
| `kill_switch` | on / off | on, fails open | Permanent switches that turn a feature off in an emergency. |
| `mode` | declared values | first value | Staged rollouts. Presets: `:sensor` (off/sensor/on), `:cutover` (off/allowlist/all), `:shadow` (off/shadow/enforce); or `values:`. |
| `experiment` | declared variants | first variant | Experiments. Resolves to its first variant (list `control` first) unless pinned by ENV or split by a runtime rule's variant weights. |
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
| `unit:` | The unit the flag targets. [Runtime rules](#runtime-rules) match members, cohorts and percentages on this unit's key. |
| `bucketing:` | On `flag`, `mode` and `experiment`: `{ version: 1 \| 2, salt: "..." }`, for a flag migrated from another system that must keep its old buckets. Needs `unit:`. |
| `remove_by:`, `final:` | On `flag`: the date it should be gone, and the value it settles on. |
| `permanent:` | On `flag`: `true` for a standing switch with no `remove_by:`/`final:`. |

The registry is validated when it loads. `StandardFlags::DefinitionError` is
raised for a reused tombstoned key, a missing owner, a `flag` without
`remove_by:`/`final:` (or a `permanent: true` flag with either), a default outside a mode's values, the same wire name
used twice for one audience, an undeclared unit, a malformed `bucketing:` or
unit `key:`, or any unknown attribute.

### Units

`unit :name, from: ->(ctx) { ... }` (or `resolver:`, any object with
`call(context)`) finds the unit's actor in a context. Runtime rules match a
unit by its **key**: `record.id.to_s` for anything with an `id`, otherwise
the value itself as a string; blank means missing. `key: ->(actor) { ... }`
normalises it in one place, such as a phone number to E.164. Pass actors by
unit name (`for: { account: account }`), or a target that answers the unit
name (`for: user` when `user.account` exists).

### Permanent flags

Some switches are never meant to be removed: environment permissions such as
demo pages, setup screens, or permission to send real messages outside
production. Declare them as a `flag` with `permanent: true`:

```ruby
flag :demo_pages, owner: "platform", permanent: true,
     default: { development: true, staging: true }, forbidden_in: :production
flag :outbound_email, owner: "platform", permanent: true, default: true
```

A permanent flag:

- takes no `remove_by:` or `final:`; declaring either raises
  `DefinitionError`;
- defaults off like any `flag`, and may default on, everywhere or per
  environment;
- evaluates exactly like any other flag: guards, ENV pins and legacy names
  all apply;
- never appears in `flags:stale` or the health check's stale warnings;
- shows `permanent` in the `remove_by` column of `flags:list`,
  `permanent: true` in `StandardFlags::Diagnostics.report`, and
  `"permanent": true` in the manifest.

Use a `kill_switch` instead when the switch is on by default and exists to
turn a feature off in an emergency.

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
4. **Runtime rule**, when [runtime rules](#runtime-rules) are on and the
   flag's rule answers. Reasons `TARGETING_MATCH`, `SPLIT`, `STATIC` or
   `KILL_SWITCH`, with a `rule_id`.
5. **Code default** for the current environment. Reason `DEFAULT`.

An ENV pin beats any database rule and keeps working with the database down.

**Test overrides beat guards.** Layer 1 answers before layer 2, so
`with_flag(:demo_pages, true)` turns a `forbidden_in: :production` flag on
even in production. That is what you want when testing the feature itself,
but it means a spec cannot prove a guard with `with_flag`. Use a real ENV pin
instead; see [Testing a guard](#testing-a-guard).

## Runtime rules

Runtime rules change a flag without a redeploy, and let it differ per
account, organisation, phone or other unit. Each flag has at most one rule,
stored in the app's own database (Postgres). They are off by default: with
`config.runtime_rules` false, nothing reads a database, ActiveRecord is never
loaded by the gem, and every flag behaves exactly as in 0.1.0.

This release has the read path. Rules are written through audited
operations in the next release; until then they can be written directly to
the tables, or held in a `MemoryStore`.

### Turning them on

```bash
bin/rails g standard_flags:migrations      # existing installs
bin/rails g standard_flags:install --runtime   # new installs: also writes the migration
bin/rails db:migrate
```

```ruby
# config/initializers/standard_flags.rb
StandardFlags.configure do |config|
  config.runtime_rules = true
  config.refresh_interval = 5                    # seconds between revision checks
  config.segment_resolver = ->(name, context) { Segments.member?(name, context.account) }
end
```

The migration creates four tables, with UUID keys when the app's generators
use them (`config.generators { |g| g.orm :active_record, primary_key_type: :uuid }`).
All four are new, so every index and constraint is created inside
`create_table` and StrongMigrations accepts it.

| Table | Holds |
|-------|-------|
| `standard_flags_rules` | One row per flag: `status` (draft, running, paused, stopped), `hash_version` and `salt`, `percentage_bps` (0–10,000), `rollout_value`, `variant_weights`, `fallthrough_value`, `stop_value`, `conditions` (platforms, version ranges, segments), attached `cohorts`, `member_count`. |
| `standard_flags_cohorts` | Named, reusable member lists of one unit, such as staff accounts. |
| `standard_flags_memberships` | A unit key in exactly one rule or cohort, with the value it serves and an optional `expires_at`. Removed rows keep `removed_at`. |
| `standard_flags_state` | One row; `revision` moves on every change. |

Stored values are strings: `on`/`off` for on/off kinds, a mode value, or a
variant. The models live in `lib/` (never `app/models`), have no
associations, and filter `unit_key` from `inspect`, because unit keys can be
phone numbers or emails.

### How a rule decides

The rule's status decides first:

| Status | Serves |
|--------|--------|
| `draft` | Nothing: the code default. |
| `paused` | The code default. Its settings are kept, so it can resume. |
| `stopped` | `stop_value` to everyone. Reason `STATIC`, rule `stopped`. |
| `running` | The first of the steps below that answers. |

1. **Direct members** of this unit. A member serving the flag's off value
   (a deny) wins over any other. `TARGETING_MATCH`, rule `deny` or `allow`.
2. **Attached cohorts** the unit belongs to. A cohort serving the off value
   wins; otherwise the first match in declared order. Rule `cohort:<key>`.
3. **Segments**, each asked of `config.segment_resolver.call(name,
   context)` in order. Skipped when no resolver is set. Rule `segment:<name>`.
4. **Client conditions**: `platforms` and `versions` (`{ "android" =>
   ">= 1.4.0" }`, compared with `Gem::Requirement` against
   `context.client[:platform]` and `[:version]`). When they aren't met, the
   rule skips straight to the fallthrough.
5. **Percentage and variants.** A unit whose rollout bucket is below
   `percentage_bps` gets `rollout_value` (on/off kinds default to `on`), reason
   `SPLIT`, rule `percentage`. With `variant_weights` (summing to 10,000),
   units inside the percentage, or every unit when there is no percentage,
   get a variant by a separate variant bucket, rule `variants`. Hash version
   1 uses `Bucket.v1(salt, key)` for both decisions; version 2 uses
   `Bucket.v2("rollout" | "variant", salt, key)`.
6. **Fallthrough**: `fallthrough_value` if set (`TARGETING_MATCH`, rule
   `fallthrough`), otherwise the code default.

A kill switch served `false` from a rule reads as `KILL_SWITCH`, so throwing
one from the database looks the same as pinning it off.

When a rule needs the unit (it has members, cohorts, segments, a percentage
or weights) and the context has no key for the flag's unit, the result is
the fallthrough or the code default with reason `ERROR` and error code
`TARGETING_KEY_MISSING`. That emits `targeting_key_missing.standard_flags`
but reports nothing, because reads with no unit are often legitimate. A
stored value the flag can't take (an unknown mode value, weights that don't
sum, a bad version range) fails only that flag: its `fail:` value with
`PARSE_ERROR`, reported once through the error reporter.

### What a read costs

* **Rules** are cached per process in an immutable snapshot: every rule,
  plus each cohort's key, unit and member count, never its members. On an
  evaluation, once `refresh_interval` has passed, one query reads
  `standard_flags_state.revision`, and the rules reload only when it moved.
  No background thread is started, so it is safe under forking servers.
* **Memberships** cost one indexed query per unit key per unit of work: it
  returns that unit's live memberships across every rule and cohort, and is
  memoised through the executor. Twenty flags checked for one account in a
  request cost one query. It is skipped entirely when the flag's rule has no
  members and no attached cohort with members.
* **Lists** load in one query with `StandardFlags.preload`, so a loop
  doesn't run a query per record:

  ```ruby
  StandardFlags.preload(:account, accounts)
  accounts.each { |account| notify(account) if StandardFlags.on?(:new_checkout, for: { account: account }) }
  ```

The spec suite asserts each of these query counts against Postgres.

### When the database is unavailable

The process keeps serving the last good snapshot, marks it stale, reports the
error once and emits `runtime_stale.standard_flags`; it tries again one
interval later. A process that has never loaded rules serves code defaults.
Inside a host transaction every read runs in a savepoint, so a failed read
can't abort the host's transaction. The read path never raises.

### Without a database

`config.runtime_store` takes any `StandardFlags::Runtime::Store`. The
in-memory `MemoryStore` serves specs and apps without a database:

```ruby
store = StandardFlags::Runtime::MemoryStore.new
store.put_rule(:new_checkout, status: :running, percentage_bps: 500)
store.put_cohort(:staff, unit: :account)
store.add_member(cohort: :staff, unit: :account, unit_key: "42", value: true)
store.put_rule(:new_checkout, cohorts: { staff: true })
StandardFlags.configure { |c| c.runtime_rules = true; c.runtime_store = store }
```

### Migrated flags

A flag moved from another system declares `bucketing: { version: 1, salt:
"old_key" }` so its units keep their buckets; the rule copies those values
when it is first written, and its salt never changes afterwards.

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
is past its first value. Replace the response everywhere with
`config.controller_responder = ->(controller, denial) { ... }`.

To keep an endpoint's existing error contract, give one guard its own
responder with `with:`. It overrides `config.controller_responder` for that
guard only:

```ruby
class Api::ReportsController < ApplicationController
  # A callable takes (controller, denial).
  requires_flag :new_reports,
                with: ->(c, denial) { c.render json: { error_code: "FEATURE_OFF" }, status: 422 }

  # A Symbol names a controller method that takes (denial).
  requires_flag :report_exports, with: :render_api_error

  private

  def render_api_error(denial)
    render json: ApiError.new(:unavailable, feature: denial.feature), status: denial.status
  end
end
```

The denial carries `key`, `error`, `status` (from `error:`/`status:`),
`feature` and `body` (the default JSON:API document). The responder must
render or redirect so the action doesn't run.

```ruby
class ReplyJob < ApplicationJob
  include StandardFlags::Job

  requires_flag :ai_assistant, retry: true, for: -> { arguments.first }
  retry_on StandardFlags::Disabled, wait: 5.minutes, attempts: 12
end
```

With `retry: true` a disabled flag raises `StandardFlags::Disabled` so
`retry_on` can reschedule. Without it the job is discarded unrun.

Jobs that already `retry_on` (or `discard_on`) their own exception can
raise it instead with `error:`, a class or a proc:

```ruby
class SyncJob < ApplicationJob
  include StandardFlags::Job

  retry_on UpstreamUnavailable, wait: :polynomially_longer, attempts: 10

  requires_flag :partner_sync, error: UpstreamUnavailable
  # or build the exception in the job instance; the proc may take the key:
  requires_flag :partner_sync, error: ->(key) { UpstreamUnavailable.new("#{key} off for #{arguments.first}") }
end
```

A class is raised with the message `flag :<key> is disabled`. A proc runs in
the job instance and returns an exception or an exception class. How the
options combine:

| Options | When the flag is off |
|---------|----------------------|
| (none), or `retry: false` | The job is discarded unrun. |
| `retry: true` | Raises `StandardFlags::Disabled`. |
| `error: SomeError` | Raises `SomeError`; the job's own `retry_on`/`discard_on` for it applies, and without one the job fails like any other error. |
| `error:` with `retry: true` | Same as `error:` alone. |
| `error:` with `retry: false` | `ArgumentError` at declaration: `error:` always raises, so it cannot also discard. |

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
| `bin/rails flags:list` | Every flag with its value, reason, deciding env var and remove_by (`permanent` for permanent flags). |
| `bin/rails flags:stale` | Flags past `remove_by`, with the `final:` value to keep. Permanent flags never appear. |
| `bin/rails flags:refs` | Scans `config.refs_paths` (default `app lib config`) for `on?(:k`, `off?(:k`, `mode(:k`, `variant(:k`, `evaluate(:k`, `requires_flag :k` and string keys. Exits non-zero for undeclared or tombstoned keys; warns for declared flags nothing reads. Run it in CI. |
| `bin/rails standard_flags:manifest` | Writes `config/flags.manifest.json`: keys, wire names, kinds, values, audiences and defaults (and `permanent` on entries of kind `flag`), deterministically. Commit it. |
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
| `runtime_refresh.standard_flags` | Runtime rules reloaded (revision, rule count). |
| `runtime_stale.standard_flags` | A runtime refresh failed; the last good rules (or code defaults) keep serving. |
| `rule_invalid.standard_flags` | A stored rule holds something its flag can't serve. |
| `targeting_key_missing.standard_flags` | A rule needs a unit key the context doesn't have. |

Built-in subscribers: **Logger** (always), **Metrics** (`Sentry::Metrics`
counters when sentry-ruby is loaded) and **Sentry** (handled warnings for
rejected and forbidden pins). Sentry is off by default because those pins
already go to `Rails.error`; enable it only when `Rails.error` isn't wired to
your error tracker. Add your own with
`config.add_notifier(->(name, payload) { ... })`.

Errors the gem reports (rejected and forbidden pins, unknown flags,
evaluation errors, invalid runtime rules, runtime store failures) go through
`Rails.error.report` as handled warnings. Set
`config.error_reporter = ->(error, context) { ... }` to send them somewhere
else instead; if it raises, the report falls back to `Rails.error`.

## Health check and diagnostics

With [standard_health](https://github.com/rarebit-one/standard_health) 0.9 or
later, the gem contributes its check through standard_health's load hook, so
an app that calls `register_default_checks` gets it as `:standard_flags`
(non-critical) with nothing else to write. Opt out or override it by name:

```ruby
StandardHealth.configure do |c|
  c.register_default_checks standard_flags: { critical: true }   # or false to skip it
end
```

It also contributes env vars to the env audit: the `STANDARD_FLAGS_<KEY>` pin
and legacy `env:` names of every `forbidden_in:` flag, as `forbidden` in
those environments whenever they pin the flag on. Other pins are optional,
which the env spec has no level for, so they aren't declared. The app's own
`env_spec` entry for a name wins.

On older standard_health, or without `register_default_checks`, register it
yourself:

```ruby
StandardHealth.configure do |c|
  c.register_check :flags, StandardFlags::HealthCheck
end
```

The check fails when a `forbidden_in` flag is pinned on, or when runtime
rules are on and their tables are missing. It warns on unparseable pins,
legacy names in use, flags past `remove_by`, `STANDARD_FLAGS_*` variables that
match no flag, a stale runtime snapshot, and runtime rules for undeclared or
tombstoned keys. standard_health has no
warning status, so warnings ride on the row (`warnings:`) and the check stays
`:ok`; pass `warn_as: :fail` to let them degrade the tier. It is non-critical
by default. There is no dependency on standard_health unless you reference
the check.

`StandardFlags::Diagnostics.report` returns the same picture as a hash for a
diagnostics page: each flag's value, reason, deciding variable and whether
it is permanent, plus
forbidden, rejected, legacy and unknown pins and stale flags. With runtime
rules on it adds each flag's `rule_status` and a `runtime:` section (store,
readiness, revision, snapshot age, staleness and each rule's status), and
`flags:list` gains a `rule` column and a header line with the revision and
age. It contains variable names only, never raw environment values.

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

Runtime rules, held in an in-memory store for the example (no database,
whatever the app's runtime configuration):

```ruby
with_rule(:new_checkout, percentage: 5_000)                  # running, 50%
with_rule(:new_checkout, status: :stopped, stop: true)
with_rule(:strict_gates, fallthrough: :sensor, platforms: %w[ios], versions: { ios: ">= 2.0" })
with_rule(:home_hero, variants: { "control" => 5_000, "savings" => 5_000 })
with_members(:new_checkout, account, value: false)           # a deny; records or keys
with_cohort(:staff, unit: :account, members: [ alice, bob ])
with_rule(:new_checkout, cohorts: { staff: true })
```

Salts and hash versions default to the flag's `bucketing:`, else the key and
version 2. Values are checked against the declaration.

Overrides are the first evaluation layer, so they beat guards, ENV pins,
runtime rules and defaults without touching `ENV`. Unknown keys, wrong kinds and undeclared
values raise; unknown keys raise on read too (strict mode); everything resets
after each example.

### Testing a guard

Because overrides beat `forbidden_in:` guards (layer 1 before layer 2), a
spec that uses `with_flag` to prove a guard passes for the wrong reason: the
override turns the flag on and the guard never runs. Prove a guard with a
real ENV pin and an explicit environment:

```ruby
it "never turns demo pages on in production, even when pinned" do
  ENV["STANDARD_FLAGS_DEMO_PAGES"] = "on"
  production = StandardFlags::Context.new(env: "production")

  expect(StandardFlags.evaluate(:demo_pages, for: production))
    .to have_attributes(value: false, reason: "DISABLED")
ensure
  ENV.delete("STANDARD_FLAGS_DEMO_PAGES")
end
```

Pins are read from `config.env_source`, which is `ENV` unless you set it; a
spec may point it at a Hash instead (`StandardFlags.config.env_source =
{ "STANDARD_FLAGS_DEMO_PAGES" => "on" }`, and set it back to `ENV` after
the example). Either
way the pin goes through the same parser and guard as in production.

## Conformance suite

`spec/fixtures/conformance/*.json` holds the evaluation contract as data.
Each file has a registry snippet and cases: environment variables and a
context in, the expected value, variant, reason, error code and deciding
variable out. `bucket_vectors.json` pins test vectors for every bucketing
version. The Ruby suite runs every case. Evaluators in other languages (a
Kotlin or TypeScript client, say) run the same files, so they cannot drift
from the server on what a flag evaluates to. `runtime/*.json` adds runtime
rules: each case's rule, cohorts and memberships plus a context (unit keys,
client, segments) in; value, variant, reason, error code and `rule_id` out,
including the v1 and v2 bucket boundaries.

## Bucketing

`StandardFlags::Bucket` holds the bucketing contract for percentage rollouts
and variant splits in runtime rules.

```ruby
StandardFlags::Bucket.v1(salt, unit_key)              # SHA-256("salt:unit_key")[0, 15] hex % 10_000
StandardFlags::Bucket.v2(:rollout, salt, unit_key)    # SHA-256("v2|rollout|salt|unit_key") ...
StandardFlags::Bucket.v2(:variant, salt, unit_key)    # a separate input for variant choice
StandardFlags::Bucket.sql_v2(column: "devices.id")    # the Postgres twin; bind :salt
```

Buckets are basis points (0–9,999). A nil or blank unit key returns nil (the
caller maps it to `TARGETING_KEY_MISSING`), never a random bucket. These
functions are permanent: a new algorithm gets a new version and existing
flags keep theirs. The Postgres CI job checks `sql_v2` against `v2` for
every vector.

## Roadmap

Phase 2 adds runtime rules stored in the database (changes without a
redeploy, allow and deny lists, cohorts, sticky percentage rollouts with
per-flag salts), audited write operations and an admin generator. The read
path is on `main`; the write operations and rake tasks come next, then MCP
tools, the admin generator and an OpenFeature provider. Phase 3
adds client delivery: an OpenFeature remote-evaluation (OFREP) endpoint,
client version targeting, a minimum-version endpoint and the manifest
contract checked in client CI. Phase 4 adds experiment exposure tracking and
staged rollout plans with automatic halts.

## License

MIT. See [LICENSE](LICENSE).
