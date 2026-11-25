# standard_flags

Feature flags, kill switches, staged modes and experiments for Rails apps.

StandardFlags is a small Rails engine. Every flag is declared once, in code,
with an owner. Values come from a fixed, documented chain: test overrides,
guards, environment pins, then per-environment code defaults. Results have
the [OpenFeature](https://openfeature.dev) shape (value, variant, reason,
error code), so "why is this on?" is always a one-line answer.

This is version 0.3.0: the registry, ENV layer and evaluation API (which
need no database tables), plus opt-in [runtime rules](#runtime-rules) stored
in the app's own database, the audited operations that change them,
[operator tools](#operator-tools-mcp), an admin page generator, an
[OpenFeature](#openfeature) provider, [client context](#client-context) (who
is calling, from request headers), portable version ranges, build-number
conditions, a raisable `FeatureDisabled`, flag-gated MCP tools and
[client delivery](#client-delivery) (an OFREP endpoint mixin, bootstrap
embeds, minimum client versions and deprecated wires). Unreleased on `main`:
[client upgrades](#client-upgrades) (a client registry, `GET /client/status`,
a 426 guard and measured compatibility windows). See [Roadmap](#roadmap).

- [Install](#install)
- [Declaring flags](#declaring-flags)
- [Reading flags](#reading-flags)
- [How a value is decided](#how-a-value-is-decided)
- [Runtime rules](#runtime-rules)
- [Environment variables](#environment-variables)
- [Sensor rollouts](#sensor-rollouts)
- [Controller and job guards](#controller-and-job-guards)
- [Client context](#client-context)
- [Client payload](#client-payload)
- [Client delivery](#client-delivery)
- [Client upgrades](#client-upgrades)
- [Client contract](#client-contract)
- [Rake tasks](#rake-tasks)
- [Observability](#observability)
- [Health check and diagnostics](#health-check-and-diagnostics)
- [OpenFeature](#openfeature)
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
| `mode` | declared values | first value | Staged rollouts. Presets: `:sensor` (off/sensor/on), `:cutover` (off/allowlist/all), `:shadow` (off/shadow/enforce); or `values:`. May declare `remove_by:` with `final:`, or `permanent: true`. |
| `experiment` | declared variants | first variant | Experiments. Resolves to its first variant (list `control` first) unless pinned by ENV or split by a runtime rule's variant weights. |
| `compat` | on / off | on | Compatibility shims that stay on until they are removed. `until_clients:` declares the client versions that still need it, and makes it a [measured window](#compatibility-windows). |
| `tombstone` | — | — | A removed key. It can never be declared again. `serve:` keeps its client wires answering a static value for a while ([Deprecated wires](#deprecated-wires)). |

### Attributes

| Attribute | Meaning |
|-----------|---------|
| `owner:` | Required on every kind. Who to ask about the flag. |
| `description:` | What it does. |
| `default:` | A value, or `{ env_name => value }`. Environments not listed get the kind's default. |
| `env:` | Legacy environment variable name(s) still honoured. See [Environment variables](#environment-variables). |
| `inverted:` | The legacy name is a `*_DISABLED` variable: legacy on means flag off. |
| `legacy_parser:` | `:strict` (default) or `:exact`: how legacy `env:` values are read. See [Exact legacy readers](#exact-legacy-readers). |
| `legacy_true:` | With `legacy_parser: :exact` on an on/off kind, the exact values that mean on. Default `%w[on]`. |
| `forbidden_in:` | Environment name(s) where the flag is forced off. A pin that tries to turn it on is reported once per process. |
| `fail:` | The value returned if evaluation raises. Kill switches default to on. |
| `expose:` | `{ audience => wire_name }`, or a list of audiences to use the key. A Hash value may list several wire names (aliases), each serving the same evaluation: `expose: { mobile: %i[chat_enabled insights_enabled], web: :chat }`. Default: not exposed. |
| `min_client:` | `{ platform => "version" }`: client builds below it, or of unknown version, are not told about the flag. See [Minimum client versions](#minimum-client-versions). Needs `expose:`. |
| `unit:` | The unit the flag targets. [Runtime rules](#runtime-rules) match members, cohorts and percentages on this unit's key. |
| `bucketing:` | On `flag`, `mode` and `experiment`: `{ version: 1 \| 2, salt: "..." }`, for a flag migrated from another system that must keep its old buckets. Needs `unit:`. |
| `remove_by:`, `final:` | On `flag` (required) and `mode` (optional, together): the date it should be gone, and the value it settles on. A mode's `final:` must be one of its values. |
| `permanent:` | On `flag` and `mode`: `true` for a standing switch with no `remove_by:`/`final:`. |
| `until_clients:` | On `compat`: `{ platform => "version" }`, the first client version per platform that no longer needs the shim. See [Compatibility windows](#compatibility-windows). |

The registry is validated when it loads. `StandardFlags::DefinitionError` is
raised for a reused tombstoned key, a missing owner, a `flag` without
`remove_by:`/`final:` (or a `permanent: true` flag or mode with either), a mode with only one of
`remove_by:`/`final:` or a `final:` outside its values, a `legacy_parser: :exact` without a legacy `env:`
name, a default outside a mode's values, the same wire name
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
production. Declare them as a `flag` (or a `mode`) with `permanent: true`:

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
- `rule_id`: the part of a runtime rule that decided (`allow`, `deny`, `cohort:<key>`, `segment:<name>`, `percentage`, `variants`, `fallthrough`, `stopped`), or nil when no runtime rule did.
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
Outside an executor run nothing is memoised. With runtime rules on, the
flag's resolved unit key is part of the memo key, so unsaved records (a nil
`id`) and units whose `key:` reads something other than `id` never share an
answer.

## How a value is decided

Each evaluation walks these layers in order and stops at the first one that
answers. Gates are never OR'd together.

1. **Test override.** `with_flag(:x, true)`. Exists only in tests. Reason `STATIC`.
2. **Guard.** `forbidden_in:` forces the off value. Reason `DISABLED`. It
   applies when either the context's `env` or the process's own environment
   is forbidden, so a caller-supplied environment can't relax it.
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
loaded by the gem, and every flag is decided by the test override, guards,
ENV pin and code default alone.

Rules change only through audited operations (see
[Changing flags](#changing-flags)), from the console, a rake task, or the
app's own admin and tools.

### Turning them on

```bash
bin/rails g standard_flags:migrations      # existing installs
bin/rails g standard_flags:install --runtime   # new installs: also writes the migrations
bin/rails db:migrate
```

The generator writes two migrations: the runtime-rule tables, and
`standard_flags_compat_stats` for [compatibility windows](#compatibility-windows).
Each is skipped when its migration file already exists, or when its table
already exists in the database (an app that squashed or deleted the first
migration), so running it again after upgrading the gem adds only the new,
additive one. `--no-check-tables` skips the database check.

```ruby
# config/initializers/standard_flags.rb
StandardFlags.configure do |config|
  config.runtime_rules = true
  config.refresh_interval = 5                    # seconds between revision checks
  config.segment_resolver = ->(name, context) { Segments.member?(name, context.account) }
end
```

Through the [OpenFeature provider](#openfeature), the segment resolver gets a
context whose actors are unit keys (strings), not records. If you use both,
handle both:

```ruby
config.segment_resolver = lambda do |name, context|
  account = context.account
  account = Account.find_by(id: account) if account.is_a?(String)  # an OpenFeature key
  account.present? && Segments.member?(name, account)
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
| `standard_flags_state` | One row; `revision` moves on every change, to the next value of its own sequence, so a number taken by a write that rolled back is never reused. A database built from `schema.rb` or `structure.sql` has the table but not the row (the migration inserts it); the first change creates it, until then every revision check reloads the rules, and the health check warns. |

Stored values are strings: `on`/`off` for on/off kinds, a mode value, or a
variant. The models live in `lib/` (never `app/models`) and have no
associations. Unit keys can be phone numbers or emails, so they are kept out
of logs and consoles; see [Privacy](#privacy).

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
4. **Client conditions**: `platforms`, `versions` (`{ "android" =>
   ">=1.4.0 <2.0.0" }`) and `builds` (`{ "android" => ">=120" }`), checked
   against the context's [client](#client-context). Every condition set for
   the client's platform must hold. When they aren't met, the rule skips
   straight to the fallthrough. See [Versions and ranges](#versions-and-ranges).
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
sum, a bad version or build range) fails only that flag: its `fail:` value with
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

* **One revision per unit of work.** The first evaluation in a request or
  job pins the rules snapshot, and every later evaluation in that run reuses
  it, so a page, a client payload or a loop never mixes two revisions.
  Outside an executor run each evaluation reads the process cache.

The spec suite asserts each of these query counts against Postgres.

### When the database is unavailable

The process keeps serving the last good snapshot, marks it stale, reports the
error once and emits `runtime_stale.standard_flags`; it tries again one
interval later. A process that has never loaded rules serves code defaults.
Inside a host transaction every read runs in a savepoint, so a failed read
can't abort the host's transaction. The read path never raises.

When a unit's membership lookup fails, the failure is reported once and
remembered for the rest of the unit of work, so an outage costs one failed
query per unit per request, not one per flag. Flags that needed it skip the
direct-member and cohort steps and carry on through segments, the split and
the fallthrough (or the code default), with reason `ERROR`, error code
`GENERAL` and the deciding step's `rule_id`. `StandardFlags.preload` never
raises either: on a store error, or a unit `key:` that raises, it reports
once (by error class, never a unit key) and returns 0, and each evaluation
then reads on its own.

A stored row whose shape no rule can have (`conditions` that isn't an
object, a cohort attachment that isn't an object, and so on) fails only its
flag, with `PARSE_ERROR` and `rule_invalid.standard_flags`, like an
unservable value.

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

### Privacy

Unit keys are stored raw, because writes and lookups need the real value.
The gem keeps them out of the places it controls:

* `Membership` values hide `unit_key` from `inspect`, `to_s` and `pp` (the
  console's inspector). `to_h` still includes it.
* When runtime rules are on, the engine adds `unit_key` to
  `ActiveRecord::Base.filter_attributes`, which is what ActiveRecord's SQL
  log filters bind values through; a model's own filter doesn't reach the
  log. The setting is global, so any other model's `unit_key` column is
  filtered too; the name is deliberately narrow.
* Membership read errors are reported by error class only, without the
  driver's message or cause, which can quote the value.
* Memberships are inserted with every value bound, never written into the
  SQL text, and lookups, updates and purge bind unit keys too.

That filter can't help when the connection has **prepared statements off**
(`prepared_statements: false`, common behind a transaction-mode connection
pooler): values are then inlined into the SQL text, which reaches SQL logs,
`sql.active_record` payloads and APM span descriptions as written. The
health check warns in that case. Either keep prepared statements on for the
connection, or make sure those sinks scrub SQL text.

### Migrated flags

A flag moved from another system declares `bucketing: { version: 1, salt:
"old_key" }` so its units keep their buckets; the rule copies those values
when it is first written, and its salt never changes afterwards.

## Changing flags

Every change to a rule, cohort or membership goes through an operation in
`StandardFlags::Operations`. Each one is called as
`.call(key_or_cohort, actor:, reason:, expected_revision: nil, **args)` and
returns a `StandardFlags::Result` (`success?`, `value`, `errors`, plus a
`code` Symbol on failure, and `warnings` for a change that committed but may
not do what you expect). It never raises for a refusal.

```ruby
ops = StandardFlags::Operations
ops::Ramp.call(:new_checkout, bps: 500, actor: current_user, reason: "5% canary")
ops::SetValue.call(:strict_gates, value: :sensor, actor: current_user, reason: "observe before enforcing")
ops::SetValue.call(:ai_assistant, value: false, actor: current_user, reason: "provider outage")  # kill switch, served at once
ops::Start.call(:new_checkout, actor: current_user, reason: "go")

ops::CreateCohort.call("staff", unit: :account, name: "Staff", actor: current_user, reason: "dogfood")
ops::AddMembers.call("cohort:staff", keys: staff_accounts, actor: current_user, reason: "dogfood")
ops::AttachCohort.call(:new_checkout, cohort: "staff", value: true, actor: current_user, reason: "dogfood")

result = ops::Pause.call(:new_checkout, actor: current_user, reason: "error spike", expected_revision: 7)
result.code  # => :stale_revision if someone changed the rule since you read revision 7
```

A successful Result's `value` has the key (or `cohort:`), the state after
the change (`rule:` or `state:`), `revision:` and `store_revision:`, plus
what the operation changed. `revision` is the number `expected_revision` is
checked against, so it can be passed straight back: a rule's `lock_version`,
or for cohort operations the store's revision. `store_revision` is always
`standard_flags_state.revision`.

**`SetValue` on a draft starts it.** A rule starts as a draft, and a draft
serves the code default, so a value set on a flag nobody had touched would
otherwise change nothing until someone also ran `Start`. Instead, `SetValue`
with a value on a draft rule (including the one it creates on first use)
moves it to running in the same write: one transaction, one revision, one
`standard_flags.flag.value_set` event and audit row, whose `before` and
`after` show both the status and the value. The running rule is checked as
`Start` checks it; if that fails, the whole operation fails with `:invalid`
and nothing changes. Anything staged on the draft (a ramp, variants,
conditions, members, cohorts) serves from then on too. The Result's value,
the event and the audit row carry `started: true`; no separate
`standard_flags.flag.started` event is published.

```ruby
result = ops::SetValue.call(:ai_assistant, value: false, actor: current_user, reason: "provider outage")
result.value[:started]  # => true when it started a draft
result.warnings         # => [] here; on a paused rule:
                        #    ["rule is paused; the value is stored but not served until Start"]
```

On a **paused** rule the value is stored but the rule stays paused (someone
stood it down on purpose), and the Result carries that warning. A running
or **stopped** rule keeps its status. Clearing the value (`value: nil`)
never starts a rule. Every other operation (`Ramp`, `SetVariants`,
`SetConditions`, `AddMembers`/`RemoveMembers`, `AttachCohort`/`DetachCohort`)
leaves a draft a draft, so changes can be staged and started together.

| Operation | Scope | Does |
|-----------|-------|------|
| `Start` | `flags:write` | Draft or paused → running, after checking everything the rule would serve. |
| `Pause` | `flags:write` | Running → paused. A paused rule serves the code default and keeps its settings, so `Start` resumes it. |
| `Stop(serve:)` | `flags:write` | → stopped, serving `serve:` to everyone (the winner, or the flag's `final:`) until the code drops the flag. |
| `Ramp(bps:, value: nil)` | `flags:ramp` | Sets the percentage (0–10,000 basis points) and, for modes and experiments, the value it serves. At 10,000 it records `full_since`. |
| `SetVariants(weights:)` | `flags:ramp` | Weights over the flag's variants or mode values, summing to 10,000. `{}` clears them. |
| `SetValue(value:)` | `flags:write` | The fallthrough value, served to every unit nothing else matched. Moves a mode off → sensor → on and throws a kill switch. Starts a draft rule (above); a paused one stays paused, with a warning. `nil` clears it. |
| `SetConditions(platforms:, versions:, builds:, segments:)` | `flags:write` | Replaces the conditions; omitted ones are cleared. Version ranges are stored in the neutral syntax. |
| `AddMembers(keys:, value:, unit:, expires_at:)` | `flags:write` | Adds units (records or keys) to a rule or a cohort. Adding an existing member with a new value or expiry keeps the old row as removed and adds a new one, so [Restore](#restore) can read it back; adding it unchanged writes nothing. |
| `RemoveMembers(keys:, unit:)` | `flags:write` | Removes them (soft delete, see retention below). |
| `CreateCohort(unit:, name:, description:)` / `ArchiveCohort` | `flags:write` | Named member lists of one unit. Archiving needs the cohort detached everywhere. |
| `AttachCohort(cohort:, value:)` / `DetachCohort(cohort:)` | `flags:write` | Attach a cohort to a flag, serving `value:` to its members. |

A target is a flag key, or a cohort as `"cohort:staff"` (or
`StandardFlags::Operations.cohort(:staff)`). Values are Ruby values or their
stored strings (`true` or `"on"`, `:sensor` or `"sensor"`). Member keys go
through the unit's `key:`, so records, raw keys and unnormalised phone
numbers all work.

### What every operation does

1. **Actor.** `actor:`, else `config.actor_resolver` (by default `Current.user`
   when the app defines `Current`). With neither, it fails
   (`:actor_missing`). Work no person does passes
   `StandardFlags::Actor.system("name")`.
2. **Policy.** `config.authorize = ->(actor, scope, key) { ... }` must return
   truthy. Scopes are `flags:read`, `flags:write` and `flags:ramp` (ramping
   is granted separately, so on-call can ramp without changing targeting).
   The key is the flag key Symbol, or `"cohort:<key>"`; `AttachCohort` and
   `DetachCohort` ask about both the flag and the cohort. The default allows
   system actors and nobody else, so wire it to your policy layer:
   ```ruby
   config.authorize = lambda do |actor, scope, _key|
     next true if actor.is_a?(StandardFlags::Actor) # rake tasks
     scope == "flags:ramp" ? actor.on_call? || actor.admin? : actor.admin?
   end
   ```
3. **Refusals.** Unknown (`:unknown_flag`) and tombstoned (`:tombstoned_flag`)
   keys, and flags an ENV pin decides (`:pinned_by_env`; the message names
   the variable, never its value). An ENV pin always beats the database, so
   writing under one would change nothing anyone sees.
4. **One transaction.** The rule is created on first use (salt and hash
   version from `bucketing:`, else a random salt and v2) and locked `FOR
   UPDATE`, then the cohorts it needs, by id; `expected_revision` is checked
   against its `lock_version` (`:stale_revision`; for cohort operations,
   against the store's revision); the change is validated and saved. A rule
   that is running afterwards is checked whole, as `Start` checks it, so no
   edit can leave one the read path would refuse. Then
   `standard_flags_state.revision` moves on. Inside the app's own
   transaction it runs in a savepoint and commits with it.
5. **Audit**, in the same transaction, in its own savepoint (below).
6. **After the commit**, never while the write's locks are held: the
   process cache is expired (so this process sees the change at once), the
   unit of work's memo is cleared, and the events go out. Inside the app's
   transaction that happens when it commits, and not at all if it rolls
   back.

Locks are always taken in one order: the rule or cohort being changed, then
cohorts by id, then memberships, then the state row; purge locks the rules
and cohorts it recounts first. So two operations, or an operation and purge,
never wait on each other.

Failures carry a `code`: `:actor_missing`, `:unauthorized`, `:invalid`,
`:limit_exceeded`, `:unknown_flag`, `:tombstoned_flag`, `:pinned_by_env`,
`:stale_revision`, `:already_exists` (`CreateCohort` on a taken key),
`:runtime_rules_off`, `:audit_failed`, `:store_error` (reported) or `:error`
(unexpected, reported). A success means the change committed (or, inside the
app's transaction, commits with it): a write whose transaction a swallowed
error aborted fails with `:store_error` instead of reporting a change that
Postgres silently rolled back.

### Validation and limits

Everything is checked on write and nothing on read (R13): values must be
ones the flag can take, weights must use its variants or mode values and sum
to 10,000, `bps` must be 0–10,000, percentages, variants, segments and
members need the flag to declare a `unit:`, version ranges must parse, and a
cohort's unit must match the flag's. Limits, each configurable:

```ruby
config.max_members = 10_000            # live members per rule or cohort
config.max_keys_per_operation = 1_000
config.max_cohorts_per_rule = 20
config.max_conditions_bytes = 64 * 1024
```

### Audit

Every operation records the actor, the reason and the full rule (or cohort)
state before and after, without members, and publishes one event:

| Event | Operation |
|-------|-----------|
| `standard_flags.flag.started` / `.paused` / `.stopped` | Start, Pause, Stop |
| `standard_flags.flag.ramped` / `.variants_set` / `.value_set` / `.conditions_set` | Ramp, SetVariants, SetValue, SetConditions |
| `standard_flags.flag.members_added` / `.members_removed` | AddMembers, RemoveMembers on a rule |
| `standard_flags.cohort.created` / `.archived` / `.attached` / `.detached` | the cohort operations |
| `standard_flags.cohort.members_added` / `.members_removed` | AddMembers, RemoveMembers on a cohort |
| `standard_flags.flag.restored` / `standard_flags.cohort.restored` | [Restore](#restore): one row per flag or cohort put back, member changes as counts |
| `standard_flags.members.revealed` | Not a change: an operator revealed members' unit keys ([Operator tools](#operator-tools-mcp)). Counts only. |
| `standard_flags.flag.probed` | Not a change: an operator evaluated a flag for one unit key, which says whether it is a member ([Operator tools](#operator-tools-mcp)). Counts only. |

The payload has `actor` (the record, or nil for a system actor),
`actor_label`, `reason`, `key` or `cohort`, `revision` and `store_revision`
(as in the Result), `before` and `after`.
Membership changes add `unit`, `value` and counts (`requested`, `added`,
`updated`, `removed`). **Unit keys never appear** in an audit row, a
notification, a Result or an error report: they can be phone numbers or
emails.

With [standard_audit](https://github.com/rarebit-one/standard_audit) loaded,
each change writes one audit row inside the operation's transaction, in its
own savepoint. Either subscribe standard_audit to the events:

```ruby
StandardAudit.configure do |config|
  StandardFlags::Events.auditable.each { |pattern| config.subscribe_to(pattern) }
end
```

or don't, and the gem writes the row itself through
`StandardAudit::Operation#audit!` (as `StandardFlags::Operations::AuditWriter`).
It checks which: there is one row either way. If your app keeps an
`AuditCatalogue::ACTIONS`, add `StandardFlags::Events.auditable` to it, or
standard_audit's declaration check fails in development and test.

standard_audit swallows a failed write by default, and on Postgres a failed
statement aborts the whole transaction; the savepoint confines the failure
to the audit row. With `raise_on_audit_write_error`, a failed audit write
fails the operation (`:audit_failed`) and rolls it back, on either path.
Without it the change commits without its row and the gem reports the loss,
as standard_audit's default does. (A failure standard_audit's subscriber
swallows before it reaches the database can't be seen from outside; it
reports those itself.)

When standard_audit's subscriber writes the row, the event is published
inside the transaction, so any other subscriber to it runs there too. In
every other case the events are published after the commit. Without
standard_audit, operations only publish the events. `change.standard_flags`
carries a one-line summary for the gem's own subscribers (the Logger line
and `config.add_notifier`), always after the commit.

### Rake tasks for break-glass changes

For a console with no admin UI. Each task needs `REASON=` (written to the
audit log), runs as `StandardFlags::Actor.system("rake")`, prints the outcome
and the new revision, and refuses pinned flags with the variable's name.
`flags:set` on a draft rule starts it and says so
(`flags:set ai_assistant: ok, revision 1 (status running, started)`); on a
paused rule it prints the warning on the next line.

```bash
bin/rails flags:show KEY=new_checkout                 # declaration, value, pin, stored rule
bin/rails flags:show KEY=cohort:staff
bin/rails flags:set KEY=strict_gates VALUE=sensor REASON="observe first"
bin/rails flags:ramp KEY=new_checkout BPS=500 REASON="5% canary"
bin/rails flags:start KEY=new_checkout REASON="go"
bin/rails flags:pause KEY=new_checkout REASON="error spike"
bin/rails flags:stop KEY=new_checkout SERVE=on REASON="winner"
bin/rails flags:members:add KEY=new_checkout KEYS=42,43 VALUE=on [EXPIRES_AT=2026-12-01T00:00:00Z] REASON="pilot"
bin/rails flags:members:remove KEY=cohort:staff KEYS=42 REASON="left"
bin/rails flags:purge REASON="weekly"
bin/rails flags:restore AT=2026-11-20T09:00:00Z [KEYS=new_checkout,cohort:staff] [APPLY=1] REASON="bad ramp"
```

The default `config.authorize` allows system actors; if you replace it, keep
allowing them or the rake tasks are refused too.

### Retention

`RemoveMembers` keeps the row with `removed_at` (and a changed membership
keeps its old row the same way), so [Restore](#restore) can put members
back. `bin/rails flags:purge` (or `StandardFlags::PurgeJob`,
an ActiveJob, defined when the app loads ActiveJob) hard-deletes memberships
removed or expired more than `config.membership_retention` ago (default 90
days). Schedule the job, for example daily.

### Stale rules

`flags:stale` also lists rules at 100% or stopped for 30 days or more, rules
not evaluated in 14 days, rules for undeclared or tombstoned keys, and
memberships past retention. "Not evaluated" comes from `last_evaluated_at`:
each process notes in memory which flags it evaluated. Nothing is written
during an evaluation. When a unit of work ends (the Rails executor's
`complete` hook, after the request or job has done its work), the gem writes
the noted flags if it hasn't in the last `config.evaluation_tracking_interval`
(default an hour), so at most once per interval per process, in one
`UPDATE`. That `UPDATE` never waits: it skips rows a write holds (`FOR
UPDATE SKIP LOCKED`), it is skipped inside an open transaction, and it
changes neither `lock_version` nor `updated_at`. A process that evaluates
flags outside the executor never writes them. A failed write is reported
once and retried, and `config.track_evaluations = false` turns it off (and
the 14-day check with it). Operator reads (the MCP tools and the admin page)
evaluate flags without noting them, so looking at a dead flag doesn't hide
it.

### Restore

`StandardFlags::Operations::Restore` (and `bin/rails flags:restore`) puts
rules and memberships back as they were at a past time T:

```ruby
restore = StandardFlags::Operations::Restore
restore.call(at: Time.utc(2026, 11, 20, 9), reason: "bad ramp")                       # dry run
restore.call(at: Time.utc(2026, 11, 20, 9), keys: %w[new_checkout cohort:staff], apply: true, reason: "bad ramp")
```

- **A rule's state at T** is the after-state of its latest audit row at or
  before T, read back through standard_audit's query API
  (`StandardAudit::AuditLog`, the `audit_logs` table). Without standard_audit
  it fails with `:audit_unavailable`. Only an audited state drives a change:
  a flag with no row at or before T is skipped ("no audit history at T; left
  unchanged"), never read as "no rule then". Rows go missing for ordinary
  reasons (the audit log's retention, auditing set up after the rule, a
  write standard_audit swallowed), and a long-thrown kill switch is exactly
  the rule nobody touches.
- **Members at T** come from the memberships table: rows created by T and
  not removed or expired then. Removed and changed rows are kept for
  `config.membership_retention`, so a T older than that is refused
  (`:retention_exceeded`). Members whose expiry has passed since T are not
  restored (the note says how many).
- **Dry run by default.** The Result lists each flag (and each cohort, for
  its members) as `unchanged`, `planned` or `skipped`, with the changes as
  text, member changes as counts.
- **`apply: true`** (`APPLY=1`) writes each flag's state at T (its
  settings, attached cohorts in their old order, and direct members) and
  each cohort's members as one store write: one revision bump, one
  `standard_flags.flag.restored` or `standard_flags.cohort.restored` row
  (the full state before and after, member changes as counts), as
  `StandardFlags::Actor.system("restore")` with the reason
  `"restore to <T>: <reason>"`. Evaluators see the state before or the state
  after, never a mix of the two, and a write that fails changes nothing.
  Inside it, members are removed before any are added, so
  `config.max_members` counts the end state. Cohorts go first, so a flag
  that attaches one serves its members as they were. Stored unit keys are
  put back as they are, not passed through the unit's `key:` again. A
  flag's write expects the revision it was planned at, so a change made
  meanwhile stops that flag (`:stale_revision`) rather than being
  overwritten. Targets are independent: when some fail the Result is a
  failure (`:partial_failure`) whose `value` still lists what was applied,
  what failed and why.
- **Skipped**, with a note: ENV-pinned flags, undeclared or tombstoned
  keys, flags with no audit history at T, and what the operations don't do
  (un-stop a rule, clear a percentage, change a rule's salt).
- **`AT=`** must name its zone (`2026-11-20T09:00:00Z` or `+08:00`); a bare
  local time is refused rather than read in the server's zone.

Restore authorises as the system actor, so it is a console and rake tool,
not an MCP tool or an admin button.

## Operator tools (MCP)

`StandardFlags::MCP` has one class per tool for an agent or chat surface,
with no dependency on any MCP framework. Each instance has `name`,
`description`, `input_schema` (a JSON Schema Hash) and
`call(arguments, actor:)`, which returns a JSON-safe Hash with String keys,
or `{ "error" => { "code" =>, "message" => } }`. Adapting them to a tool
registry takes a few lines:

```ruby
StandardFlags::MCP.tools.each do |tool|
  server.register_tool(name: tool.name, description: tool.description, input_schema: tool.input_schema) do |arguments, context|
    tool.call(arguments, actor: context.user)
  end
end
```

| Tool | Scope | Does |
|------|-------|------|
| `list_flags` | `flags:read` (per flag) | Every flag the actor may read: kind, owner, values, value with no unit, source, ENV pin, rule summary. |
| `get_flag` | `flags:read`; with `unit_key`, `flags:write` and `reason` | One flag: value, reason, `rule_id` and source (`env_pin`, `runtime_rule`, `guard`, `code_default`, `error`, `test_override`), the ENV pin and the stored rule in full. With `unit_key` (normalised through the unit's `key:`, masked in the answer) it evaluates for that unit, which is a reveal (below). |
| `start_flag`, `pause_flag`, `stop_flag`, `ramp_flag`, `set_flag_value` | as the operation | Run Start, Pause, Stop, Ramp and SetValue. `set_flag_value` returns `started: true` when it started a draft, and `warnings` when the rule is paused. |
| `list_members` | `flags:read` | One page (`offset`, `limit` up to 200) of a flag's (`key`) or a cohort's (`cohort`) members. |
| `add_members`, `remove_members` | `flags:write` | Run AddMembers and RemoveMembers on a flag or a cohort. |
| `list_cohorts`, `get_cohort` | `flags:read` (per cohort) | Cohorts with their unit, member count, archived state and the flags they're attached to. |

- **Reads** ask `config.authorize` for `"flags:read"`; `list_flags` and
  `list_cohorts` list only what the actor may read, and so do the
  cross-references: a cohort's `attached_to` names only flags the actor may
  read (`hidden_flags` counts the rest), and a flag's `rule.cohorts` only
  cohorts it may read (`cohort:<key>`; `hidden_cohorts` counts the rest).
  Reads never mark a rule as evaluated. **Writes** go through
  the operations, need `reason` and accept `expected_revision` (the rule's
  `revision` from `get_flag`). A failed operation's code is the error code:
  `pinned_by_env`, `stale_revision`, `unauthorized`, `invalid` and so on.
- **Pins** show as `{ "env_var" => "STANDARD_FLAGS_X", "label" => "Pinned by environment (STANDARD_FLAGS_X)" }`,
  never the variable's value.
- **Unit keys are masked** (`•••4567`: the last four characters, fewer for
  short keys so at least half stays hidden). `list_members` shows them in
  full only with `reveal: true` and a `reason`, for an actor allowed
  `"flags:write"` on the target. A reveal publishes (and with standard_audit,
  records) `standard_flags.members.revealed` with the actor, reason, flag or
  cohort and counts, never the keys. `get_flag` with `unit_key` says
  whether that unit is a member (and the mask gives away its last four), so
  it is a reveal too: `"flags:write"` on the flag, a `reason`, and a
  `standard_flags.flag.probed` row with counts and no key.
- **Reveals fail closed** when standard_audit's
  `raise_on_audit_write_error` is set: keys (or a probe's answer) come back
  only once the row is known to be written. The row is written in a store
  transaction savepoint, so a failure standard_audit's subscriber swallows
  still aborts it, and is read back by a one-off `audit_ref`. With
  standard_audit's `config.async` the row can't be confirmed, so the read is
  refused. Without `raise_on_audit_write_error`, a lost row is reported and
  the read goes ahead, as for writes.
- **One instance per tool is safe to share** across threads and actors (as
  an MCP server registers them): it is frozen, and each call runs on its
  own copy holding that call's actor, arguments and store read.
- A missing `actor:` falls back to `config.actor_resolver`. The generated
  admin page never relies on that (below).
- `list_flags` and `get_flag` evaluate with no client unless the tools are
  built with one: `StandardFlags::MCP.tools(client: ...)` takes a
  `StandardFlags::Client`, a Hash or a lambda (which may take the actor).

### Gating your own tools

An app's own tools can require flags. Include `StandardFlags::MCP::Gated`
in any tool class with the same shape (`name`, `description`,
`input_schema`, `call(arguments, actor:)`):

```ruby
class SummariseThread
  include StandardFlags::MCP::Gated

  requires_flag :ai_assistant                                    # evaluated for the actor
  requires_flag :thread_tools, for: ->(actor) { actor.account }, client: -> { Current.client }

  def name = "summarise_thread"
  # description, input_schema, call(arguments, actor:) ...
end
```

While a required flag is off, `call` returns
`{ "error" => { "code" => "feature_disabled", "message" => "threadTools is disabled" } }`
without running the tool, and `StandardFlags::MCP.visible` leaves the tool
out of `tools/list`. The message names the flag's wire name for the `:mcp`
audience, else its first wire name, else the key. The gate holds in every
subclass, including one that defines its own `call`. A
`StandardFlags::FeatureDisabled` raised inside any tool (gated or not, the
gem's own included) comes back as the same error, and isn't reported as a
failure.

List and call through the same two helpers, with the same arguments, and
they agree by construction: a tool listed for a request is callable by it,
and one hidden from it is refused.

```ruby
client = StandardFlags::Client.from_headers(request.headers)
tools = app_tools + StandardFlags::MCP.tools

server.on_list_tools { |user| StandardFlags::MCP.visible(tools, actor: user, client: client) }
server.on_call_tool do |user, name, arguments|
  tool = tools.find { |candidate| candidate.name == name } or raise UnknownTool, name
  StandardFlags::MCP.call(tool, arguments, actor: user, client: client)
end
```

`visible(tools, actor:, context: nil, client: nil)` and
`call(tool, arguments, actor:, context: nil, client: nil)` evaluate each
gate for `context:` when given (else the gate's own `for:`, by default the
actor) and for `client:` when given (else the gate's own `client:`). A nil
`actor:` resolves through `config.actor_resolver`, as the gem's own tools
do. Calling `tool.call(arguments, actor:)` directly evaluates as `visible`
does with no `context:` or `client:`. Ungated tools always appear. The gem's
own tools are not gated.

## Admin page

```bash
bin/rails g standard_flags:admin [--path=/admin/flags] [--base-controller=ApplicationController] \
  [--controller=Admin::FlagsController] [--pages-path=app/javascript/pages] [--actor-method=current_user]
bin/rails standard_flags:typescript
```

It writes code your app owns and restyles:

- **A controller** inheriting from `--base-controller` (where your admin
  authentication lives), with `index`, `show` and one action per operation
  (`start`, `pause`, `stop`, `ramp`, `set_value`, `add_members`,
  `remove_members`). Every request runs as the signed-in user, from
  `--actor-method` (default `current_user`); when that is nil it answers 401
  (`standard_flags_deny`, yours to change to a redirect) before any tool
  runs, and never falls back to `config.actor_resolver`, which may return a
  system actor for jobs. Pages read through the MCP tools, so
  `config.authorize` decides who sees what and members stay masked. Each
  action calls its operation with the form's reason and the revision the
  page showed, then redirects back with a flash.
- **Unit keys are posted as `unit_keys`**, which Rails' default
  `config.filter_parameters` (`_key`) keeps out of the request log and error
  trackers. If your app's list doesn't match it, add `:unit_keys`. An MCP
  host should likewise not log `get_flag`'s `unit_key` or the member tools'
  `keys` arguments.
- **Routes** under `--path`: `GET /`, `GET /:id`, `POST /:id/<operation>`,
  named `standard_flags_flags`, `standard_flags_flag` and
  `standard_flags_<operation>_flag`.
- **Two Inertia pages**, `standard_flags/index.tsx` and `show.tsx`, in plain
  semantic markup with no styling framework, typed from the
  `standard_flags:typescript` output (`FlagList`, `FlagDetail`,
  `FlagMemberPage`, `FlagAuditEntry`). The show page has the rule, the
  members (masked, paged), recent audit entries when standard_audit is
  loaded, and a form per operation. A pinned flag is read-only, labelled
  "Pinned by environment (VAR)".

The gem never reads these files back: move the routes, cut operations, or
restyle the pages freely.

## Environment variables

Every flag can be pinned with its canonical variable, `STANDARD_FLAGS_<KEY>`
(the key upcased): `STANDARD_FLAGS_NEW_CHECKOUT=on`.

One strict parser reads every value, trimmed and case-insensitive (a flag
may opt its legacy names into [exact reading](#exact-legacy-readers)):

- on/off kinds: `on`/`off`, `true`/`false`, `1`/`0`, `yes`/`no`;
- modes: a declared value; experiments: a declared variant.

Anything else is ignored and reported once per process per variable, through
`Rails.error.report(handled: true)` and a `pin_rejected.standard_flags`
notification. A blank value counts as unset (except under
[exact reading](#exact-legacy-readers), where a blank legacy on/off value pins off).

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

### Exact legacy readers

Some legacy readers were exact, `ENV["X"] == "on"`, and code that destroys
data may rely on that: `X=true` or `X=ON` never turned it on. To keep an
exact reader's meaning, declare `legacy_parser: :exact`:

```ruby
flag :purge_inactive, owner: "platform", permanent: true,
     env: "ACME_PURGE_INACTIVE", legacy_parser: :exact
flag :bulk_export, owner: "reporting", permanent: true,
     env: "ACME_BULK_EXPORT", legacy_parser: :exact, legacy_true: %w[on enabled]
mode :strict_gates, owner: "platform", preset: :sensor,
     env: "ACME_STRICT_GATES", legacy_parser: :exact
```

- It applies to legacy `env:` names only. The canonical
  `STANDARD_FLAGS_<KEY>` pin is always read by the strict parser.
- On/off kinds: a value in `legacy_true:` (default `%w[on]`) means on; any
  other non-blank value pins off, as the old reader did, and is never
  reported as rejected. `inverted: true` still flips the result.
- Modes and experiments: a value matches only if it equals a declared value
  exactly (case-sensitive, no trimming); anything else is rejected and
  reported like any unparseable pin.
- Matching does no trimming or case folding.
- A legacy variable that is set but blank (`X=""`, `X=" "`) pins an on/off
  flag off, as `ENV["X"] == "on"` did, so blanking the variable disarms the
  flag even when a runtime rule or default would serve on. Only an unset
  variable falls through. Two exceptions keep blank as unset: an `inverted:`
  name (pinning it would turn the flag on) and modes and experiments, where
  no value is "off". The canonical pin always treats blank as unset.

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
  not change behaviour. For a probe whose errors are expected, pass
  `report: false` (`StandardFlags.sensor(:strict_gates, for: run, report:
  false)`): the error is still swallowed and its class still rides on the
  notification (and the Logger line), but nothing is reported.
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

`requires_client_version` answers 426 to builds below their enforced
minimum through the same responder chain; see [Answering 426](#answering-426).
A global responder receives both kinds of denial and can tell them apart by
`denial.error`.

### Raising FeatureDisabled

Code deeper than a `before_action` can raise the same denial:

```ruby
StandardFlags.require!(:ai_assistant, for: Current.account)   # raises StandardFlags::FeatureDisabled when off
raise StandardFlags::FeatureDisabled.new(:ai_assistant)         # or raise it yourself
```

Inside an action, evaluate for the same context the guards use (this
request's `standard_flags_context` plus its client):

```ruby
StandardFlags.require!(:ai_assistant, for: standard_flags_request_context)
standard_flags_reader.on?(:ai_assistant)
```

`StandardFlags::FeatureDisabled` (a `StandardFlags::Error`) carries `key`,
`feature` (the wire name, found as for `meta.feature`) and `status` (403
unless given). `StandardFlags::Controller` rescues it and renders it exactly
like a `requires_flag :key` denial: through `config.controller_responder`
when one is set, else the JSON:API body above. One raised with
`status: 404` answers like `error: :not_found`, with no `meta.feature`.

This holds even when the app declares `rescue_from StandardError` after
including the module (Rails would otherwise try that handler first, since
it tries the last declared first). An app takes `FeatureDisabled` over only
by naming it, `rescue_from StandardFlags::FeatureDisabled, with: ...`;
`config.controller_responder` is usually the better hook. Nothing is
rendered for one raised after the action has already rendered.

An app whose API already has its own error envelope renders every denial,
from guards and from the exception alike, with one responder:

```ruby
StandardFlags.configure do |config|
  config.controller_responder = lambda do |controller, denial|
    controller.render json: { error: { code: denial.error.to_s.upcase, feature: denial.feature } },
                      status: denial.status
  end
end
# => 403 {"error":{"code":"FEATURE_DISABLED","feature":"assistant"}}
```

Keep client-facing denials in the 4xx range. Some hosting edges and proxies
replace 5xx response bodies with their own error page, so a client may
never see a 503's body; 4xx bodies pass through. `status: 503` still works
for server-to-server endpoints that only read the status.

```ruby
class ReplyJob < ApplicationJob
  include StandardFlags::Job

  requires_flag :ai_assistant, retry: true, for: -> { arguments.first }
  retry_on StandardFlags::Disabled, wait: 5.minutes, attempts: 12
end
```

With `retry: true` a disabled flag raises `StandardFlags::Disabled` so
`retry_on` can reschedule. Without it the job is discarded unrun.

`client:` evaluates the flag for a client as well (a `StandardFlags::Client`,
a Hash, or a lambda run in the job instance). Jobs never read request
headers; pass along the client the request saw (`client.to_h` serialises):

```ruby
requires_flag :new_importer, for: -> { arguments.first }, client: -> { arguments.second }
```

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

## Client context

Clients (mobile apps, desktop apps, devices, browsers) say who they are on
every request with three headers:

```
X-Client-Platform: android
X-Client-Version: 1.4.0
X-Client-Build: 381
```

`StandardFlags::Controller` reads them once per request into
`standard_flags_client`, a `StandardFlags::Client`, and evaluates every
guard and payload for `standard_flags_context` plus that client. If your
`standard_flags_context` returns a context that already has a client, it is
kept.

```ruby
client = StandardFlags::Client.from_headers(request.headers)
client.platform  # => "android"
client.version   # => #<StandardFlags::Version 1.4.0>
client.build     # => 381
```

- **Platform** is downcased and must be one of `config.client_platforms`
  (default `%w[android ios web desktop]`).
- **Version** must parse as a [version](#versions-and-ranges).
- **Build** must be 1 to 18 ASCII digits.

A version or build that fails is dropped, as if the header were missing. A
platform that fails becomes `"unknown"`. Each emits
`client_invalid.standard_flags` (with the field and header name, never the
value). Nothing raises, whatever bytes arrive (invalid UTF-8 included), and
nothing is reported as an error, because the headers come from outside.

Version and build ranges are scoped to a platform, and a rule reads the
client like this:

| Client | Platform list | That platform's version and build ranges |
|--------|---------------|------------------------------------------|
| Recognised platform | must list it | must hold |
| No platform (no headers, as in 0.2.2) | fails | don't apply |
| `"unknown"` platform (sent but not recognised) | fails | fail |

So a request with no headers is evaluated exactly as 0.2.2 evaluated an
empty client: a rule with only `versions: { android: ">=9.0.0" }` still
reaches it. Add `platforms:` to a rule that must reach only the listed
platforms. A misspelt platform header (`andriod`) can't step around a
version floor, because an unknown platform fails every platform-scoped
condition.

```ruby
StandardFlags.configure do |config|
  config.client_headers = { platform: "X-App-Platform", version: "X-App-Version", build: "X-App-Build" }
  config.client_platforms = %w[android ios]
  config.read_client_headers = false   # opt out: controllers never read the headers
end
```

Outside a controller, pass a client explicitly. Nothing else reads headers.

```ruby
StandardFlags.on?(:new_checkout, for: StandardFlags::Context.wrap(account, client: client))
StandardFlags.on?(:new_checkout, for: StandardFlags::Context.new(actors: { account: account },
                                                                 client: { platform: "ios", version: "2.1.0" }))
```

`Context.new(client:)` still takes the Hash form, which keeps its values as
given (no allowlist). `context.client` is a `StandardFlags::Client`, a
frozen Hash subclass, so 0.2.2's reads (`[:platform]`, `fetch`, `dig`,
`key?`, `each`, `to_h`) work unchanged. The typed readers `platform`,
`version` and `build` parse the values: a version given as a
`Gem::Version` or a Float is read through `to_s`. Jobs and MCP tools take
`client:` too (see [Controller and job guards](#controller-and-job-guards)
and [Operator tools](#operator-tools-mcp)).

### Versions and ranges

`StandardFlags::Version` is SemVer 2.0: `MAJOR.MINOR.PATCH`, an optional
`-prerelease` and an ignored `+build`. The shorthands `MAJOR.MINOR` and
`MAJOR` mean the missing parts are 0 (`1.4` is `1.4.0`); they take no
suffix. Ordering is SemVer precedence: a prerelease sorts before its release
(`1.4.0-rc.1 < 1.4.0`), numeric prerelease identifiers compare by value and
below alphanumeric ones, and build metadata never counts
(`1.4.0+381 == 1.4.0`). `v1.4`, `1.4.0.1` and leading zeros don't parse.
Numbers have no size limit; a version is at most 128 characters.

Version ranges are comparators (`>=`, `>`, `<=`, `<`, `=`) separated by
spaces, all of which must hold, with optional `||` alternatives.
Whitespace after an operator is optional, and means ASCII spaces and tabs
only. A range is at most 1024 characters:

```
>=1.4.0 <2.0.0
>=0.9.0 || =0.8.5-beta.1
>= 1.4 < 2
```

The syntax is deliberately small so the Kotlin and TypeScript clients can
implement it; `version_ranges.json` in the [conformance suite](#conformance-suite)
pins its meaning. Comparison is plain ordering, so `<2.0.0` admits
`2.0.0-beta.1`, and a shorthand is an exact version rather than a wildcard:
`>1.4` admits `1.4.1`, and `<=1.4` excludes `1.4.5`. A client version that
doesn't parse meets no neutral range.

Build ranges use the same comparators over build numbers (1 to 18 digits,
leading zeros allowed, no sign): `>=120 <200`. A rule's `builds` sit beside
its `versions`, per platform, and both must hold:

```ruby
StandardFlags::Operations::SetConditions.call(:new_checkout, actor: admin, reason: "needs the new SDK",
  platforms: %w[android ios], versions: { android: ">=1.4.0" }, builds: { android: ">=120" })
```

Ranges written with 0.2.x used RubyGems syntax (`">= 1.4.0"`, `"~> 1.4"`,
`">= 1.4, < 2"`). Stored ones that only RubyGems can read keep evaluating
exactly as `Gem::Requirement` evaluates them, prerelease client versions
included. A string valid in both syntaxes (`">= 1.4.0"`,
`">= 1.0.0-alpha"`) is read as neutral, so a SemVer client version is
compared by SemVer (for release operands the answer is the same).

- One with a neutral equivalent is translated: `~> 1.4` reads as
  `>=1.4.0 <2.0.0-0`, `~> 1.4.2` as `>=1.4.2 <1.5.0-0`, and `!= 1.5` as
  `<1.5.0 || >1.5.0`. The `-0` is SemVer's lowest prerelease, so
  `<2.0.0-0` excludes `2.0.0-beta.1` as well as `2.0.0`, matching RubyGems,
  whose `~>` compares only the release part.
- One the neutral syntax can't hold is evaluated with `Gem::Requirement` and
  doesn't block operations on the rule. That covers more than three release
  segments (`>= 1.4.0.1`), more than 64 alternatives' worth of `!=`, and any
  prerelease operand (`= 1.4.0.beta`, `~> 2.0.0.pre`), because RubyGems
  orders prereleases differently from SemVer: it reads a client's
  `1.4.0-beta` as `1.4.0.pre.beta`.
- A client version outside SemVer (`1.4.0.1`, `1.4.0.beta`, passed in the
  Hash form; headers require SemVer) is read by RubyGems against any range
  RubyGems can read, `">= 1.4.0"` and `">=0.0.0"` included, as 0.2.2 did.
  This is the one place the server and the portable fixture differ (see
  [Conformance suite](#conformance-suite)). Ranges only the neutral syntax
  can read compare SemVer only.
- Build metadata in a client version is ignored, as SemVer says: a Hash-form
  `version: "1.4.0+381"` meets `~> 1.4`, where 0.2.2 refused it.

`SetConditions` accepts either syntax and stores the neutral form: a
neutral range as given, a RubyGems one translated, and one the neutral
syntax can't hold as given. `StandardFlags::VersionRange.translate`
converts one by hand.

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
which makes it a safe ETag. Each alias of a flag gets the same value.

This flat payload is for pages the server renders: it ignores `min_client:`
and tombstones' static wires. Clients with builds of their own (mobile apps,
devices) use [client delivery](#client-delivery) instead.

With Inertia:

```ruby
class ApplicationController < ActionController::Base
  include StandardFlags::Controller
  inertia_share features: -> { standard_flags_payload(:web) }
end
```

## Client delivery

Mobile apps, devices and MCP clients learn what is on from the same
evaluation the server uses, in the shape of OpenFeature's Remote Evaluation
Protocol (OFREP, validated against its OpenAPI document 0.4.0). One builder,
`StandardFlags::Delivery`, feeds two outlets: an OFREP endpoint the app
mounts behind its own authentication, and an embed for responses the client
already fetches (a bootstrap `/me`, a device check-in, MCP whoami).

### Audiences

`expose:` names audiences. Declare them per app to have the registry check
every name, and to mark the ones served before sign-in:

```ruby
StandardFlags.configure do |config|
  config.audiences = { web: {}, mobile: {}, pre_auth: { public: true, unit: :install } }
end
```

Without `config.audiences`, every audience a flag exposes to is a private
audience, as in 0.2. When it is set, an undeclared `expose:` or `serve:`
audience fails boot, and building a payload for an undeclared audience raises
when `config.strict` is on (and is empty otherwise).

### The OFREP endpoint

```ruby
# config/routes.rb
post "ofrep/v1/evaluate/flags", to: "flags#ofrep_evaluate_flags"
post "ofrep/v1/evaluate/flags/:key", to: "flags#ofrep_evaluate_flag"

# app/controllers/flags_controller.rb
class FlagsController < Api::BaseController   # ActionController::API
  include StandardFlags::OFREP::Controller
  standard_flags_ofrep audience: :mobile        # on ::Base, add csrf: (below)

  before_action :authenticate!                 # your own; 401/403 stay yours

  private

  def standard_flags_context = current_account
end
```

```http
POST /ofrep/v1/evaluate/flags
Authorization: Bearer …
X-Client-Platform: android
X-Client-Version: 0.5.0
Content-Type: application/json

{ "context": { "targetingKey": "ignored", "platform": "android", "appVersion": "0.5.0" } }
```

```http
200 OK
ETag: "4b2eec86…"
Cache-Control: no-cache, private
Vary: Authorization, X-Client-Platform, X-Client-Version, X-Client-Build

{ "flags": [
    { "key": "chat_enabled",     "value": false,     "reason": "KILL_SWITCH", "variant": "off" },
    { "key": "chat_v1",          "value": false,     "reason": "STATIC",      "variant": "off" },
    { "key": "homeHero",         "value": "savings", "reason": "SPLIT",       "variant": "savings" },
    { "key": "insights_enabled", "value": false,     "reason": "KILL_SWITCH", "variant": "off" },
    { "key": "brokenFlag", "errorCode": "PARSE_ERROR", "errorDetails": "the flag could not be evaluated; use the code default" }
  ],
  "metadata": { "version": "4b2eec86…" } }
```

- **Who it evaluates for.** Units come from `standard_flags_context`, the
  authenticated caller. The body's `targetingKey` is ignored, so a client
  can't choose who it is evaluated as. The body may only add client
  attributes (`platform`, `appVersion` or `app_version`, `build`). They are
  checked like the X-Client-* headers, and a header wins over the same body
  attribute. A context that already names a client keeps it. With
  `config.read_client_headers` off, the request contributes no client at
  all, from headers or body.
- **Entries.** One entry per wire name, ordered by it. An entry carries a
  value, a variant and a reason (STATIC, DEFAULT, TARGETING_MATCH, SPLIT,
  DISABLED, ENV_PIN or KILL_SWITCH; KILL_SWITCH lets a client say
  "temporarily unavailable"). A flag whose evaluation failed gets OFREP's
  error entry instead, and the client uses its code default; the other flags
  are unaffected. No flag key, rule ID, env var name, unit key or unexposed
  flag ever appears.
- **Statuses.** A Content-Type other than `application/json` (any charset)
  gets 415, and a malformed body gets 400, both as
  `{"errorCode":"INVALID_CONTEXT","errorDetails":…}`. On the single-flag path, a wire the audience isn't told
  about (a server-only flag, another audience's wire, a flag the client is
  too old for) gets 404 `FLAG_NOT_FOUND`, so server-only keys stay invisible.
  A flag whose evaluation failed gets 400 with its error code. Every status
  the mixin sends is 2xx, 304 or 4xx: some edges replace 5xx bodies, so a
  client would never see them.
- **The request is checked first.** Before Rails' instrumentation (which
  decodes a JSON body), your filters, authentication and forgery protection
  run, the mixin checks the media type and reads the body itself. It refuses
  a declared Content-Length over 64 KiB without reading, reads at most
  64 KiB otherwise, and checks UTF-8 and JSON. The bytes it read are what
  Rails parses afterwards, if anything asks for `params`. These 415 and 400
  answers say nothing about the caller, and come outside the rescue chain,
  so an app's `rescue_from StandardError` can't turn them into a 5xx. Put
  your own request-size limit in the web server too: the cap bounds what the
  mixin reads, not what the server buffers.

#### Forgery protection on `ActionController::Base`

Rails protects `::Base` controllers from cross-site request forgery by
default, and a bearer-token client sends no CSRF token, so on such a
controller you must choose:

```ruby
standard_flags_ofrep audience: :mobile, csrf: :skip     # bearer-token APIs
standard_flags_ofrep audience: :mobile, csrf: :protect  # cookie sessions; clients send the token
```

- `csrf: :skip` skips forgery protection for the two OFREP actions only. It
  is safe because the endpoints accept only `Content-Type:
  application/json`, which a cross-site form can't send without a CORS
  preflight, and because the responses aren't readable cross-origin. Use it
  when requests authenticate with a bearer token or API key.
- `csrf: :protect` keeps Rails' check: use it when the endpoint
  authenticates with a session cookie, and have the client send the token
  (or use the [embed](#embeds) instead).

Leaving `csrf:` out on a controller with forgery protection raises
`StandardFlags::ConfigurationError` when the class is declared, or on the
first request if `protect_from_forgery` comes later, instead of answering
every request 422. `ActionController::API` controllers have no forgery
protection and need neither.

OFREP's schema lists only STATIC, TARGETING_MATCH, SPLIT, DISABLED and
UNKNOWN as success reasons. OpenFeature treats reasons as an open set, and the
gem also sends DEFAULT, ENV_PIN and KILL_SWITCH. OFREP providers pass the
string through.

### Caching and ETags

The ETag is the SHA-256 of the audience plus the RFC 8785 canonical JSON of
the entries (sorted keys, no whitespace, strings as raw UTF-8). It depends only on what this client is
told, never on the config revision, so a client that switches user never gets
a 304 for answers that differ. Two users told the same thing share an ETag,
and a 304 is then correct. `If-None-Match` naming it (quoted or bare, weak or
strong, never `*`) gets 304 with no body. `metadata.version` carries the same
value, so a client bootstrapped from an embed can send it as If-None-Match.
A single-flag 200 carries a strong ETag over its one entry and honours
If-None-Match the same way.

### Embeds

```ruby
render json: { profile: profile, features: standard_flags_payload(:mobile, format: :ofrep) }
StandardFlags.payload(:device, for: device, client: { platform: "android", version: "2.1.0" }, format: :ofrep)
# => { "flags" => [...], "metadata" => { "version" => "…" } }
```

The embed returns the bulk endpoint's body, built the same way. The flat
format stays the default, and `payload_digest` still hashes the flat payload.

### Minimum client versions

```ruby
flag :new_checkout, owner: "payments", remove_by: "2027-06-01", final: true,
                    expose: { mobile: :checkoutV2 }, min_client: { android: "0.4.0", ios: "0.4.0" }
```

A client on a listed platform below the minimum is not told about the flag.
Neither is one whose version is missing or unparseable, nor one that sends
no platform: an unknown build never receives a `min_client` flag. Platforms
the declaration doesn't list are unaffected. Platforms come from
`config.client_platforms`, and precedence is SemVer's (`0.4.0-rc.1` is below
`0.4.0`). That is stricter than the [client registry](#client-upgrades)'s
minimum, where a prerelease of exactly the minimum release meets it: a
`0.4.0-beta` build passes a client minimum of `0.4.0` but not
`min_client: { android: "0.4.0" }`.

A kill switch can't declare `min_client:` (the registry refuses it): a
withheld entry means the client's code default, which for a kill switch is
"available", so an old build would never see the feature pulled.

### Deprecated wires

When a flag a shipped client reads is removed, keep its wire answering until
those builds are gone:

```ruby
tombstone :chat_v1, removed: "2026-12-01", serve: { mobile: { chat_v1: false } },
                    until: "2027-03-01", until_clients: { android: "0.6.0" }
```

The wire is served with reason STATIC through `until:` and disappears the
day after. `until:` is required with `serve:`, and is compared with today's
date in UTC, so every host switches the wire off at the same moment. With
`until_clients:`, a client on that platform at or above the version stops
receiving it sooner. A client of unknown version keeps receiving it until
`until:`; `until_clients:` never extends it. A static wire can't reuse a
live wire name. Once `until:` has passed, `flags:stale` lists
the `serve:` block as removable. `standard_flags:manifest:check` fails CI
when a client wire disappears without such a tombstone
([Client contract](#client-contract)).

### Before sign-in

```ruby
class PreAuthFlagsController < ActionController::API
  include StandardFlags::OFREP::Controller
  standard_flags_ofrep audience: :pre_auth, anonymous: true
end
```

An `anonymous: true` controller serves only a `public: true` audience, and
never calls `standard_flags_context`. Flags exposed to a public audience may
target by client attributes, and by the audience's `unit:` (an install ID,
say), whose key is the body's `targetingKey`. Every other unit resolves to
nothing. Runtime rules skip segments, since an app's segment resolver may
read whoever is signed in. The registry refuses a public-audience flag on any
other unit. Everything else is invisible before sign-in.

Pre-auth answers are public: anyone who sends an install ID reads what that
install gets, memberships included. Use install IDs the client generates at
random (a UUID, say), never guessable ones. When a public-audience flag's
runtime rule has members or cohorts, the gem logs a warning when rules load
(`public_targeting.standard_flags`) and lists it in the diagnostics.

### Trust model

The server decides. Clients receive only evaluated values for their
audience, never rules, allowlists, env names or the existence of server-only
flags. Client attributes (headers or body) only shape what a client is told
(`min_client:`, rule conditions). They never choose the user, so a forged
version can at most withhold a flag or show a value meant for another build.
Never gate authorisation on a client-reported version.

## Client upgrades

Tell old builds to upgrade, and refuse the ones that must. The policy lives
in code, with ENV break-glass pins; nothing is stored.

### The client registry

```ruby
# config/flags.rb
StandardFlags.define do
  client :android_app, platform: :android, min_version: "0.4.0", since: "2026-12-01",
                       recommended: "0.5.0", available: "0.5.0", grace: 7.days,
                       store_url: "https://play.google.com/store/apps/details?id=com.example.app"
  client :ios_app, platform: :ios, min_version: "2.0.0", since: "2026-12-01", available: "1.9.0",
                   store_url: "https://apps.apple.com/app/id000000000",
                   store_lookup: StandardFlags::Stores::AppStore.new(bundle_id: "com.example.app", country: "us")
end
```

| Attribute | Meaning |
|-----------|---------|
| `platform:` | Required. One of `config.client_platforms`. |
| `min_version:` | The oldest build allowed to keep working. Needs `since:`. |
| `since:` | The date (`YYYY-MM-DD`, UTC) the minimum was raised; a Time or DateTime counts as its UTC date. Enforcement starts at `since + grace`. **When you raise `min_version:`, move `since:` to that day**, or the old date enforces the new minimum at once. |
| `grace:` | Whole days before a raised minimum is enforced: `7.days` (the default), `14` or `0`. |
| `recommended:` | Builds below it are nudged, never blocked. Must not be below `min_version:`. |
| `available:` | The newest version known to be in the store (set it when review passes). The store ceiling, below. |
| `store_lookup:` | This client's live source for `available` (see below). It only ever caps this client. |
| `store_url:` | Where the client sends the user (an http(s) URL). |
| `group:` | Lets a second app share a platform. Clients are unique per platform within a group; the status endpoint and the guard pick a group (none by default). |

The registry is checked when it loads: a platform outside
`config.client_platforms`, a version or date that doesn't parse, a minimum
without `since:` (or `since:` alone), `recommended:` below `min_version:`, a
part-day `grace:`, a `store_url:` that isn't http(s), a `store_lookup:` that
can't be called, two clients on one platform in one group, or a flag whose
pin collides with a client's pin all raise `StandardFlags::DefinitionError`.

**Break-glass pins.** `STANDARD_FLAGS_CLIENT_<NAME>_MIN_VERSION`, `_SINCE`,
`_RECOMMENDED` and `_AVAILABLE` beat the code and any store lookup, as a
flag's pin beats its default (for `:android_app`,
`STANDARD_FLAGS_CLIENT_ANDROID_APP_MIN_VERSION`). Lower a minimum that went
out too high with `_MIN_VERSION` alone. To raise one, pin `_SINCE` with it:
a raised `_MIN_VERSION` without `_SINCE` is ignored, so a break-glass raise
always gets its own grace window. A pin lowers the minimum only when every
version that meets the code's minimum also meets the pin, so a prerelease of
the code's minimum (`0.4.0-rc.1` against `0.4.0`) is a raise: it stops
`0.4.0-beta.1`, which `0.4.0` lets through. A value that doesn't parse is
ignored too.
Pins in force are listed in the diagnostics (`clients:`), as flags' pins
are, and never warn; ignored pins are health check warnings, by name only.

### Grace and the store ceiling

A raised minimum is enforced from `since + grace`, compared with today's UTC
date, so every host flips on the same day. Until then, builds below it are
told `upgrade_recommended` with the date (`enforce_at`).

The enforced minimum is never above the newest version known to be in the
store, so raising the minimum before a release passes review locks nobody
out. `recommended` is capped the same way, since nudging toward a build
nobody can install helps no one. The newest version is a pinned
`_AVAILABLE` if there is one, else the client's `store_lookup:` answer if
it has one, else `available:`.

A store lookup belongs to the one client that declares it. It is any object
whose `call(client_app)` answers its last known version (or nil) at once:
it is asked on request threads, so it must never wait on the network.
`StandardFlags::Stores::AppStore.new(bundle_id:, country:)` asks Apple's
public iTunes lookup API in the background: the first call answers nil (so
`available:` applies) and starts a refresh on a thread, and later calls
answer the last good version. It refreshes at most once an hour per process.
After a failure, or when its runner can't start the refresh, it keeps the
last good answer and waits 5 minutes, doubling with each further failure up
to an hour. Each fetch has one overall 5-second deadline (connect, TLS,
request and body), with each phase's own timeout a little shorter so a
stalled connection is closed by net/http, and a 256 KiB body cap; the
connection is closed on every path. `refresh!` fetches on the calling
thread, for a warm-up at boot. Failures emit
`store_lookup_failed.standard_flags` (`store`, `client`, `reason`) once the
fetch has ended; nothing raises. Google Play has
no public API for this (it needs a service account), so Android clients use
`available:` alone: set it when a release reaches production. A store
version that isn't SemVer (`2.1.0.4`) reads as unknown.

### The status endpoint

```ruby
# config/routes.rb
get "client/status", to: "client_status#client_status"

class ClientStatusController < ActionController::API   # ActionController::Base works too
  include StandardFlags::ClientStatus::Controller
  standard_flags_client_status                          # group: :kiosk, max_age: 60
end
```

Route it outside authentication; it reveals nothing about the caller. It is
a GET, so forgery protection never applies. It reads the client exactly as
the [426 guard](#answering-426) and the flag guards do
(`standard_flags_upgrade_client`): the client your `standard_flags_context`
names, whole, when it names one (the app chose it, from a trusted device
record, say), else the X-Client-* headers' client, whole. Fields from the
two are never mixed. So a build the guard refuses is always told why here.
Keep that context safe to call before sign-in (nil, the default, is). It
answers 200 with:

```json
{ "status": "upgrade_recommended", "platform": "android", "version": "0.3.9",
  "min_version": "0.4.0", "recommended": "0.5.0", "enforce_at": "2026-12-08",
  "store_url": "https://play.google.com/store/apps/details?id=com.example.app" }
```

| `status` | When |
|----------|------|
| `unknown` | No platform, one the app doesn't recognise, or no usable version. An unknown build is never told to upgrade. |
| `upgrade_required` | Below the enforced minimum, on or after `enforce_at`. |
| `upgrade_recommended` | Below the minimum during its grace window (with `enforce_at`), or below `recommended`. |
| `ok` | Anything else, including a recognised platform with no client declared. |

Every key is always present (null when absent). Versions are canonical
SemVer (`0.4` is sent as `0.4.0`) and compare by SemVer precedence, with one
exception: a prerelease of exactly the minimum or recommended version meets
it, so a beta or TestFlight build of the required release (`1.5.0-beta.2`
against `1.5.0`) isn't locked out. A prerelease of an older version
(`1.4.9-rc.1`) is still below it. `min_version` and `recommended` are the
values after the store ceiling. `enforce_at` is set whenever the version is
below the minimum. The response carries `Cache-Control: max-age=60,
private` and a Vary on the client headers. With `config.read_client_headers`
off it can't see the headers. A client that receives a status it doesn't
know should treat it as `unknown` and never block on it.
`StandardFlags::ClientStatus.for(client)` gives the same answer in Ruby, for
a bootstrap response or a device check-in.

### Answering 426

```ruby
class Api::OrdersController < Api::BaseController
  requires_client_version                     # only:/except:, group:, with:
end

class Api::StatusController < Api::OrdersController
  skip_client_version_check                   # only:/except:
end
```

A request whose client is `upgrade_required` gets **426**
`client_upgrade_required` through the same responder chain as
`requires_flag`: the guard's `with:`, then `config.controller_responder`,
then a JSON:API body, sent whatever the request's Accept header says (the
client needs `min_version` and `store_url` to act on it):

```json
{"errors":[{"status":"426","code":"client_upgrade_required","meta":{"min_version":"0.4.0","store_url":"https://…"}}]}
```

The responder receives a `StandardFlags::Controller::UpgradeDenial` (`key`
is the client's name, `error` is `:client_upgrade_required`, `status` 426,
`feature` nil, plus `platform`, `version`, `min_version` and `store_url`),
so one responder can tell it from a feature denial by `error`. A build in
its grace window, or below `recommended` only, passes. So does one whose
platform or version is unknown, unless `config.require_client_version =
true`. The guard reads the same client as the status endpoint and the flag
guards.

There is one guard per controller hierarchy. Declaring it again, in the same
class or in a subclass of a guarded class, raises
`StandardFlags::ConfigurationError`, because the new declaration would
silently replace the earlier one (its actions, group and responder). Pass
`override: true` to replace it on purpose. To narrow an inherited guard, use
`skip_client_version_check only:/except:` in the subclass. Client-facing denials stay 4xx (403 and 426):
some edges replace an app's 5xx body with their own page. HTTP defines 426
for protocol upgrades and expects an `Upgrade` header; here it means "upgrade
the app", with no `Upgrade` header.

App code can raise `StandardFlags::ClientUpgradeRequired.new(status)` (a
`ClientStatus` result, or keywords). The controller answers it like the
guard, even when the app declares `rescue_from StandardError` after including
`StandardFlags::Controller`; only an app's own `rescue_from
StandardFlags::ClientUpgradeRequired` takes it over.

### Compatibility windows

A compat flag with `until_clients:` is a shim you mean to delete once every
build that needs it is gone:

```ruby
compat :legacy_form_auth, owner: "identity", until_clients: { android: "0.1.12", ios: "1.3.0" }
```

With `config.track_compat = true` (off by default; it needs runtime rules and
the `standard_flags_compat_stats` migration), each evaluation of such a flag
counts a hit per platform (`unknown` for a platform the app doesn't
recognise, `none` when the evaluation carried no client). The oldest client
version seen is recorded only for platforms in `config.client_platforms`.
Versions come from client headers, which anyone can send, so treat it as a
hint, not proof; it starts over once a platform has gone unused for 14 days.

Counts are held in memory and written behind like `last_evaluated_at`:
never during an evaluation, and at most once per
`config.evaluation_tracking_interval` per process when a unit of work ends,
failed writes included. A failed write is reported once per process, emits
`compat_tracking_failed.standard_flags` once per interval, and keeps the
counts for the next try. A write skipped inside a transaction is tried again
at the next unit of work. Every write that succeeds also refreshes each
window's tracking marker: when tracking began, and when a write last
succeeded. A tracking process writes once per interval even without hits,
so a quiet window still shows tracking is healthy.
A forked child starts with no pending counts. Operator reads (MCP tools,
diagnostics) don't count. Every evaluation counts, so a shim checked on
every request (or in a `StandardFlags.snapshot`) never looks idle; evaluate
it only on the legacy path.

`flags:stale` says a window "can be removed" only when tracking has run for
at least 14 days, a write has succeeded in the last 2 days, no hit has
landed in the last 14 days, and the window has passed on every listed
platform. While writes are failing it says "tracking unhealthy since"
the last successful write, since missing hits then prove nothing. A platform's window has passed when every
client declared for it enforces a minimum at or above the listed version
today (UTC), or when no build below it has used the flag (no hits from that
platform, or its oldest version seen is at or above it). Until tracking is
14 days old it says "not enough data" with the date tracking began. The
diagnostics (`compat:`, with `tracking_since` and `last_flushed_at`) and the MCP `get_flag` tool
show the window and the stored counts.
## Client contract

The committed manifest is the contract between the server and the clients
built against it. `standard_flags:manifest` writes it, `standard_flags:manifest:check`
keeps server CI honest about it, and the Kotlin and TypeScript generators
turn it into client types.

### The manifest (version 2)

`bin/rails standard_flags:manifest` writes `config.manifest_path` (default
`config/flags.manifest.json`). Commit it.

```json
{
  "version": 2,
  "audiences": { "mobile": { "public": false }, "pre_auth": { "public": true } },
  "flags": [
    { "key": "ai_assistant", "kind": "kill_switch", "type": "boolean", "values": [true, false],
      "default": true, "audiences": { "mobile": ["chat", "chatEnabled"] }, "min_client": {} },
    { "key": "new_checkout", "kind": "flag", "type": "boolean", "values": [true, false],
      "default": { "*": false, "staging": true }, "audiences": { "mobile": ["newCheckout"] },
      "min_client": { "android": "0.4.0" }, "permanent": false, "remove_by": "2027-03-01", "final": true }
  ],
  "tombstones": [
    { "key": "chat_v1", "removed": "2026-12-01", "serve": { "mobile": { "chat_v1": false } },
      "until": "2027-03-01", "until_clients": { "android": "0.6.0" } }
  ]
}
```

- `audiences` lists every audience a flag or tombstone serves, plus any
  `config.audiences` declares, and whether each is served before sign-in.
- A flag's `audiences` gives every wire name per audience, aliases included,
  in declared order. `type` is the wire's JSON type: `boolean`, or `string`
  for modes and experiments. `default` is a value, or per environment with
  `"*"` for the rest.
- `min_client` is always present (`{}` without one). `permanent` is on
  entries of kind `flag` and `mode`; `remove_by` and `final` only when
  declared.
- A tombstone with deprecated wires carries `serve`, `until` and
  `until_clients` (`{}` when not given).
- `owner:` and `description:` are left out on purpose. Client repositories
  copy this file, so it holds only what a client can already learn from the
  wire, plus lifecycle dates. Operators read owners through `flags:list`,
  `flags:show` and the MCP tools.

The JSON Schema is `conformance/schema/manifest.schema.json`. The reader
refuses anything the schema rejects, plus what a schema can't say: a
`version` that isn't the integer 2, dates that aren't calendar dates, and a
wire listed twice for one audience. Version 1 files (0.3.0 and earlier) are
still read, so the check can compare an old committed file and report what
upgrading changes. Regenerate after upgrading the gem.

The file is generated text: keep formatters and line-ending conversion away
from it. Put `config/flags.manifest.json -text` in `.gitattributes` and the
path in `.prettierignore`. The check tolerates CRLF line endings and
trailing newlines; other reformatting makes it stale.

### Checking it in server CI

`bin/rails standard_flags:manifest:check` compares the committed manifest
with the registry. It exits with:

| Exit | Meaning | Fix |
|------|---------|-----|
| 0 | The committed file matches what `standard_flags:manifest` writes (CRLF line endings and trailing newlines aside). | — |
| 1 | Stale (or missing): the registry changed. The output lists what changed per flag and tombstone. | Run `standard_flags:manifest` and commit. |
| 2 | The client contract is broken. Either a wire the baseline told an audience is gone without a tombstone serving it, or a wire changed type, or a public audience serving wires became private (clients before sign-in lose them all). | Keep the wire (or the audience public), or tombstone the wire with `serve:` and `until:`, or use a new wire name. |
| 2 | The baseline given as `BASE=` is missing or unreadable, or a manifest can't be read. | Fix the CI step; see below. |

A wire counts as served by a tombstone only while its `until:` is today or
later (UTC). A deprecated wire whose `until:` has passed in the baseline may
be deleted: its window is over. Moving a wire to another flag of the same
type is fine. Moving it to another audience removes it from the first.
Two things print a warning without failing:
- moving a deprecated wire's `until:` earlier, since shipped clients were
  promised the later date;
- adding a wire whose generated Kotlin name is an existing wire's in the
  same audience (`new_checkout` beside a shipped `newCheckout`). See
  [Kotlin](#kotlin) for how constants stay put.

The baseline is `BASE=`, the base branch's manifest, so a PR that
regenerates the file in the same commit still can't drop a wire. Without
`BASE=` the committed file stands in, and the check prints a warning that a
regenerated file hides removals. A `BASE` file that is missing, a directory
or unreadable fails with exit 2, and a stale committed file is still
reported. `BASE_OPTIONAL=1` forgives only a file that doesn't exist: set it
for first adoption, when the base branch has no manifest yet. The contract
checks are then skipped, with a warning.

```yaml
# .github/workflows/ci.yml, in a job with the app's Ruby and database set up.
- uses: actions/checkout@v4
- name: Flag manifest
  env:
    BASE_REF: ${{ github.base_ref || 'main' }}
  run: |
    MANIFEST="$(bin/rails runner 'print StandardFlags.config.manifest_path')"
    test -n "$MANIFEST" || { echo "could not read config.manifest_path" >&2; exit 1; }
    git fetch --no-tags --depth=1 origin "$BASE_REF"
    mkdir -p tmp
    if git cat-file -e "FETCH_HEAD:$MANIFEST" 2>/dev/null; then
      git show "FETCH_HEAD:$MANIFEST" > tmp/base.manifest.json
      bin/rails standard_flags:manifest:check BASE=tmp/base.manifest.json
    else
      # First adoption: the base branch has no manifest yet.
      bin/rails standard_flags:manifest:check BASE=tmp/base.manifest.json BASE_OPTIONAL=1
    fi
```

The path comes from `config.manifest_path`, so the step can't look in the
wrong place. A failed fetch fails the step (the default shell exits on
error), and `git show` runs only when the file exists at the base, so no
error turns into a skipped check. In the one PR that moves the manifest,
pass `BASE=` the old path's contents yourself.

`StandardFlags::Tooling::ManifestCheck` is the same check as a class, for
apps with their own CI scripts.

### Kotlin

`bin/rails standard_flags:kotlin` writes plain Kotlin (no dependencies) to
`config.kotlin_path` (default `config/StandardFlags.kt`) in
`config.kotlin_package` (nil writes no package line):

```kotlin
// Generated by `bin/rails standard_flags:kotlin`. Do not edit by hand.
// Manifest version 2, sha256 9c1f….

package com.example.flags

object StandardFlagsManifest {
    const val VERSION: Int = 2
    const val SHA256: String = "9c1f…"
}

enum class FeatureType { BOOLEAN, STRING }

enum class MobileFeature(val wire: String, val type: FeatureType) {
    CHAT("chat", FeatureType.BOOLEAN),
    CHAT_ENABLED("chatEnabled", FeatureType.BOOLEAN),
    @Deprecated("No longer declared; served as a static value through 2027-03-01")
    CHAT_V1("chat_v1", FeatureType.BOOLEAN),
    /** Values: [HomeHeroValue]. */
    HOME_HERO("homeHero", FeatureType.STRING),
    ;

    companion object {
        fun fromWire(wire: String): MobileFeature? = values().firstOrNull { it.wire == wire }
    }
}

enum class HomeHeroValue(val value: String) {
    CONTROL("control"),
    SAVINGS("savings"),
    ;

    companion object {
        fun fromValue(value: String?): HomeHeroValue? = values().firstOrNull { it.value == value }
    }
}
```

- There is one `<Audience>Feature` enum per manifest audience, with one
  entry per wire, ordered by wire name. Deprecated static wires are included
  and marked `@Deprecated`.
- There is one `<Key>Value` enum per mode or experiment exposed to any
  audience, in declared order.
- Entry names are SCREAMING_SNAKE_CASE (`homeHero` becomes `HOME_HERO`).
  Values that can't start an identifier get `V_` (`2fa` becomes `V_2FA`).
- Names are stable across regenerations. The task reads the file it wrote
  last time (`config.kotlin_path`), and every wire and value keeps the name
  it had there; only new ones are named. A `new_checkout` alias added after
  a shipped `newCheckout` gets a suffixed name and never takes
  `NEW_CHECKOUT`. Delete the file to name everything afresh. Commit it, or
  restore it in CI before regenerating, so names survive a clean checkout.
- A new name never fails on a clash:
  - When two wires of one audience map to the same name (`new_checkout` and
    `newCheckout`, the alias pair a rename leaves), the spelling that already
    is the name in some case (`new_checkout`, else `NEW_CHECKOUT`) keeps it,
    unless an existing wire holds it. Every other spelling gets `_` plus 8
    hex digits of the SHA-256 of its exact spelling
    (`NEW_CHECKOUT_1F0A2B3C`), and its KDoc says why.
  - When two values of one flag map to the same name, later ones in
    declared order get the first free `_2`, `_3`, and so on.
- The source is ASCII: every other character is escaped.
- `SHA256` is `Tooling::Manifest#digest`, the SHA-256 of the canonical
  manifest: exactly what `standard_flags:manifest` writes, with LF line
  endings. It equals the committed file's hash when the file is current and
  untouched by line-ending conversion. A client build can compare it with
  the server's manifest to tell whether its copy is current.

### TypeScript

`bin/rails standard_flags:typescript` keeps the `<Audience>Features`
interfaces, `FlagKey` and `FlagValues` as before. It adds, from the
manifest:

- one `<Audience>Wire` union per audience (deprecated static wires
  included), and `WiresByAudience`;
- the OFREP shapes: `OfrepEvaluationRequest` (with `appVersion` or
  `app_version`), `OfrepEvaluationSuccess<W>`,
  `OfrepEvaluationFailure<W>`, `OfrepBulkResponse<W>`, `OfrepFlagNotFound`,
  `OfrepInvalidContext`, `OfrepReason`, `OfrepErrorCode`, and
  `OfrepBulkResponseByAudience`.

### In client CI

A client copies (or fetches) the server's manifest. The client library's
contract check compares the wires its generated enums were built from with
the server's current manifest. It fails on a wire the audience no longer
exposes or serves, or on a changed type, exactly as server CI does.
`conformance/wire/manifest_check.json` pins those semantics: committed and
current manifests and today's date in; ok, stale, removed wires and type
changes out. The Kotlin library's Gradle task runs it. The server and client
checks therefore agree on what breaks a shipped build.

## Rake tasks

| Task | What it does |
|------|--------------|
| `bin/rails flags:list` | Every flag with its value, reason, deciding env var and remove_by (`permanent` for permanent flags). |
| `bin/rails flags:stale` | Flags and modes past `remove_by`, with the `final:` value to keep. Permanent ones never appear. Tombstones whose `serve:` block is past `until:`. With runtime rules on, also stale rules and memberships due for purge ([Stale rules](#stale-rules)), and with `config.track_compat`, compat windows ready to remove ([Compatibility windows](#compatibility-windows)). |
| `bin/rails flags:show KEY=` | One flag's declaration, value here, ENV pin and stored rule; `KEY=cohort:<key>` for a cohort. |
| `bin/rails flags:set` / `ramp` / `start` / `pause` / `stop` / `members:add` / `members:remove` / `purge` | Break-glass changes through the audited operations ([Rake tasks for break-glass changes](#rake-tasks-for-break-glass-changes)). |
| `bin/rails flags:restore AT=` | Rules and memberships as they were at `AT`, from the audit log; a dry run unless `APPLY=1` ([Restore](#restore)). |
| `bin/rails flags:refs` | Scans `config.refs_paths` (default `app lib config`) for `on?(:k`, `off?(:k`, `mode(:k`, `variant(:k`, `evaluate(:k`, `requires_flag :k` and string keys. Exits non-zero for undeclared or tombstoned keys; warns for declared flags nothing reads. Run it in CI. |
| `bin/rails standard_flags:manifest` | Writes `config/flags.manifest.json` (version 2): audiences, and per flag its wire names per audience, kind, type, values, defaults, `min_client` and lifecycle; tombstones with their deprecated wires. Deterministic. Commit it ([The manifest](#the-manifest-version-2)). |
| `bin/rails standard_flags:manifest:check BASE= [BASE_OPTIONAL=1]` | Exits 1 when the committed manifest is stale or missing. Exits 2 when a wire the baseline told a client is gone without a tombstone, a wire changed type, a public audience went private, `BASE` is unavailable, or a manifest can't be read ([Checking it in server CI](#checking-it-in-server-ci)). |
| `bin/rails standard_flags:kotlin` | Writes `config.kotlin_path`: a `<Audience>Feature` enum per audience, a `<Key>Value` enum per mode and experiment, `FeatureType`, and the manifest's version and digest ([Kotlin](#kotlin)). |
| `bin/rails standard_flags:typescript` | Writes a `.d.ts` with a `Features` interface per audience (`WebFeatures`, `MobileFeatures`, …) keyed by wire name, a `<Audience>Wire` union per audience, `FlagKey` and `FlagValues` (every key and its stored values), the OFREP request and response types, and the shapes of the MCP tools' results that the [admin page](#admin-page) uses. |

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
| `change.standard_flags` | An operation's change committed (event, key or cohort, actor label, revision, store revision). The full events are `standard_flags.flag.*` and `standard_flags.cohort.*` ([Audit](#audit)). |
| `standard_flags.members.revealed` | An operator revealed members' unit keys (actor, reason, target, counts). |
| `standard_flags.flag.probed` | An operator evaluated a flag for one unit key (actor, reason, flag, unit, counts). |
| `purge.standard_flags` | Memberships purged (counts). |
| `evaluation_tracking_failed.standard_flags` | Writing `last_evaluated_at` failed; it is retried. |
| `report_registry_full.standard_flags` | The once-per-process report registry reached its cap (1,000 entries); new warnings are no longer reported in this process. |

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

Without `register_default_checks` (or on standard_health older than 0.9),
register it by hand: `c.register_check :flags, StandardFlags::HealthCheck`.

The check fails when a `forbidden_in` flag is pinned on, or when runtime
rules are on and their tables are missing. It warns on unparseable pins,
legacy names in use, flags past `remove_by`, `STANDARD_FLAGS_*` variables that
match no flag, a runtime store that can't be reached (flags keep serving
through a database blip, so this isn't a failure), a stale runtime snapshot,
prepared statements being off (see [Privacy](#privacy)), a missing
`standard_flags_state` row, runtime rules for
undeclared or tombstoned keys, client registry pins that were ignored
(pins in force are listed, not warned about), and compat stats that can't
be read (or `config.track_compat` without runtime rules). standard_health has no
warning status, so warnings ride on the row (`warnings:`) and the check stays
`:ok`; pass `warn_as: :fail` to let them degrade the tier. It is non-critical
by default. There is no dependency on standard_health unless you reference
the check.

`StandardFlags::Diagnostics.report` returns the same picture as a hash for a
diagnostics page: each flag's value, reason, deciding variable and whether
it is permanent, plus
forbidden, rejected, legacy and unknown pins and stale flags. With runtime
rules on it adds each flag's `rule_status` and a `runtime:` section (store,
readiness, any unreachable error class, store warnings, revision, snapshot
age, staleness and each rule's status), and
`flags:list` gains a `rule` column and a header line with the revision and
age. With a client registry it adds `clients:` (each client's values in
force, `enforce_on`, the pins that applied and those ignored; a store lookup
is never asked here), and with compat windows `compat:` (each window, when
its tracking began and, when tracking, its stored counts). It contains variable names only, never
raw environment values.

## OpenFeature

Apps that read flags through the
[openfeature-sdk](https://github.com/open-feature/ruby-sdk) gem can put the
registry behind it. The SDK is optional: standard_flags doesn't depend on it,
and nothing loads the provider until you require it.

```ruby
# Gemfile
gem "openfeature-sdk"

# config/initializers/open_feature.rb
require "standard_flags/open_feature"

OpenFeature::SDK.configure do |config|
  config.set_provider(StandardFlags::OpenFeature::Provider.new)
end

client = OpenFeature::SDK.build_client
client.fetch_boolean_value(flag_key: "new_checkout", default_value: false,
                           evaluation_context: OpenFeature::SDK::EvaluationContext.new(targeting_key: account.id.to_s))
```

Requiring `standard_flags/open_feature` without the SDK raises a `LoadError`
that says to add it. Each fetch walks the same chain as
`StandardFlags.evaluate`, so test overrides, guards, pins and runtime rules
all apply.

| Kind | Fetch | Value |
|---|---|---|
| `flag`, `kill_switch`, `compat` | `fetch_boolean_value` | `true` / `false` (variant `"on"` / `"off"`) |
| `mode` | `fetch_string_value` | the value's name, e.g. `"sensor"` |
| `experiment` | `fetch_string_value` | the variant |

- **Mismatches.** Any other pairing, and every number, integer, float or
  object fetch, returns your default with `TYPE_MISMATCH`, reported once.
- **Unknown keys** return your default with `FLAG_NOT_FOUND`, even when
  `config.strict` is on. The provider never raises.
- **Reasons and error codes** map one to one. `ENV_PIN` and `KILL_SWITCH`
  pass through as custom reasons, which OpenFeature allows.
- **`flag_metadata`** carries `kind`, plus `rule_id` and `source_env_var`
  when they are set.
- **Errors serve your default.** The SDK client replaces the value with
  the caller's default whenever there is an error code. So through OpenFeature,
  a flag's `fail:` value (a kill switch failing open, say), the
  fallthrough served with `TARGETING_KEY_MISSING`, and the decision made when
  the membership lookup fails (core still decides by segment, percentage or
  fallthrough but marks it `ERROR`/`GENERAL`) never reach the caller. Pass
  the default you want on failure.
- **Lifecycle.** `metadata.name` is `"standard_flags"`. There is no `init`,
  so the provider is ready as soon as it is set, and it emits no events;
  `shutdown` does nothing.

The evaluation context becomes a `StandardFlags::Context`:

- `targeting_key` is the key of the flag's declared unit.
- A field named after a unit (`organization`, say) sets that unit's key. For
  a flag on that unit, it wins over `targeting_key`.
- `platform`, `appVersion` (or `app_version`) and `build` become the client,
  for client conditions.
- `env` is ignored unless you construct the provider with
  `Provider.new(allow_env_override: true)`. Then it picks the environment for
  per-environment defaults. It never relaxes a `forbidden_in:` guard, which
  also checks the process's own environment. It is off by default because
  `env` is a common attribute name in merged global, transaction and client
  contexts.

Other fields are ignored. The flag's own unit key (its unit's field, else
`targeting_key`) must be a String, Symbol or Integer; anything else (a Hash,
say) returns your default with `INVALID_CONTEXT`. Other units' fields that
aren't scalars are dropped, so structured attributes in a merged context
don't break flags that don't use them.

**Keys are used as given.** A unit's `from:` and `key:` turn records into
keys, and OpenFeature callers already pass keys, so the provider applies
neither. Pass the key exactly as runtime rules store it: `record.id.to_s` by
default, or whatever your `key:` lambda returns (the normalised phone number,
not the raw one).

**The segment resolver gets keys too.** `config.segment_resolver` receives
the same keys-only context, so a resolver written for records
(`context.account.plan`) would raise, and every segmented rule would serve
your default with `GENERAL`. Write it to accept a key string as well as a
record; see the example under [Runtime rules](#runtime-rules).

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
around each example.

Every helper works in the example, in a `before` hook, or in an `around`
hook that wraps `example.run`:

```ruby
around { |example| with_flag(:new_checkout, true) { example.run } }
```

The reset runs in a config-level `around` hook, outside every group-level
one. Overrides set before an example starts (in `before(:context)`, at load
time, or in a `config.around` registered before `require
"standard_flags/rspec"`) would be discarded, so the example fails with an
error that says so. `flags:` metadata is applied in `before`, so it wins
over an `around` override of the same key.

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

`conformance/` (shipped in the gem) holds the contract as data, with a JSON
Schema (`conformance/schema/fixture.schema.json`) every fixture validates
against, and [its own README](conformance/README.md). Each file is tagged
`scope: "server"` (ENV pins, legacy variables, runtime rules, the write path,
bucketing) or `"wire"` (what clients run). `conformance/*.json` holds the
evaluation contract.
Each file has a registry snippet and cases: environment variables and a
context in, the expected value, variant, reason, error code and deciding
variable out. `bucket_vectors.json` pins test vectors for every bucketing
version. The Ruby suite runs every case. Evaluators in other languages (a
Kotlin or TypeScript client, say) run the same files, so they cannot drift
from the server on what a flag evaluates to. `runtime/*.json` adds runtime
rules: each case's rule, cohorts and memberships plus a context (unit keys,
client, segments) in; value, variant, reason, error code and `rule_id` out,
including the v1 and v2 bucket boundaries. `runtime/client.json` covers
client conditions: neutral version ranges, prerelease ordering, shorthand
versions, build ranges, and clients with no platform or an unknown one.
Cases marked `"scope": "server"` exercise the RubyGems compatibility only
the Ruby server keeps; other evaluators skip them.

`versions/version_ranges.json` is for clients: a version and a range in,
`matched` true or false out, the same for build numbers, plus ranges every
implementation must refuse, with the length and whitespace limits in its
description. It uses only the neutral syntax. The Ruby suite runs every case
through both the client reading (`VersionRange.neutral`) and the server's
read path. The five cases marked `server_matched` are where they differ: the
server reads a client version that isn't SemVer (`1.4.0.1`) through RubyGems
against a range RubyGems can also read (`>=0.0.0`), for 0.2.2
compatibility. That only applies to versions an app passes in a context's
client Hash, since client headers drop versions that aren't SemVer.
`versions/legacy_ranges.json` (`"scope": "server"`) pins how RubyGems
ranges stored by 0.2.x translate and evaluate, against `Gem::Requirement`.

`wire/delivery.json` pins what the server sends: registry, context and
client in, OFREP entries and ETag out (aliases, `min_client:` with known,
unknown and older versions, deprecated wires, errored flags, ETag equality
across users and clients). `wire/client_state.json` pins what a client does
with a payload: on, off and not loaded, a missing value meaning the code
default, ceilings, and payloads refused by size or shape.
`wire/client_status.json` pins `GET /client/status`: the recognised
platforms, the client registry, header values and today's date in, the
status payload out (unknown builds, grace, enforcement, prereleases, the
store ceiling, groups). `upgrade/client_status_server.json` (`"scope":
"server"`) adds ENV pins and store lookups. None of them needs Ruby to run.
`wire/manifest_check.json` pins the [client contract](#client-contract)
check: committed and current manifests in; stale, removed wires and type
changes out. Its manifests validate against
`conformance/schema/manifest.schema.json`. None of them needs Ruby to run.

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

Phase 1 (0.1.0) shipped the registry, the ENV layer and the evaluation API.
Phase 2 (0.2.x) shipped runtime rules stored in the database (allow and
deny lists, cohorts, segments, client conditions, sticky percentage rollouts
and variants), the audited write operations and rake tasks, the MCP
operator tools, the admin generator, `flags:restore` and the OpenFeature
provider.

Phase 3 is client delivery. On `main` now: client context from request
headers, portable version ranges, build conditions, `FeatureDisabled` and
gated MCP tools, an OFREP endpoint mixin and an embeddable payload with
ETags, minimum client versions and deprecated wires, and the portable
conformance suite, a client registry with `GET /client/status`, a 426 guard,
grace windows and a store ceiling, and measured compatibility windows. Next:
the manifest contract checked in client CI and the Kotlin client library. Phase 4 adds
conformance suite, and the client contract (manifest version 2,
`standard_flags:manifest:check`, Kotlin and TypeScript generators). Next: an
upgrade endpoint and compatibility windows. Phase 4 adds
experiment exposure tracking and staged rollout plans with automatic
halts.

## License

MIT. See [LICENSE](LICENSE).
