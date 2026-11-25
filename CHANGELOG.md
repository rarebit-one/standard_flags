# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Client registry.** `client :name, platform:, min_version:, since:,
  recommended:, available:, store_url:, store_lookup:, grace:, group:` in
  config/flags.rb (`StandardFlags::ClientApp`). `since:` is required with
  `min_version:` (a Time or DateTime counts as its UTC date); a raised
  minimum is enforced from `since + grace` (whole days, default 7, UTC
  dates), so raising `min_version:` means moving `since:`. Clients are
  unique per platform within a `group:`. Validated at boot, including flag
  pins that would collide with a client's pins. `Registry#clients` and
  `Registry#client_for(platform, group:)`.
- ENV break-glass pins `STANDARD_FLAGS_CLIENT_<NAME>_MIN_VERSION`, `_SINCE`,
  `_RECOMMENDED` and `_AVAILABLE` beat the code and any store lookup. A
  raised `_MIN_VERSION` without `_SINCE` is ignored, so a break-glass raise
  gets its own grace window; a lowered one needs no `_SINCE`. A pin lowers
  the minimum only when every version meeting the code's minimum also meets
  it, so a prerelease of the code's minimum is a raise. Pins in force
  are listed in `Diagnostics.report[:clients]` (never health warnings);
  ignored pins are health warnings, by name only. Client pins are no longer
  listed as unknown `STANDARD_FLAGS_*` variables.
- **Store ceiling.** The enforced minimum, and the recommended version, are
  never above the newest version known to be in the store: a pinned
  `_AVAILABLE`, else the client's `store_lookup:` answer, else `available:`.
  A lookup belongs to one client and only caps that client; it answers its
  last known version at once and never waits on the network.
  `StandardFlags::Stores::AppStore.new(bundle_id:, country:)` asks Apple's
  public iTunes lookup API in the background (a thread; one refresh at a
  time per process, a forked child starts its own): at most hourly, backing
  off from 5 minutes up to an hour after failures (a runner that can't
  start counts as one), with one overall 5-second deadline per fetch,
  shorter phase timeouts, the connection closed on every path, and a 256 KiB
  body cap; `refresh!` fetches synchronously. Failures emit
  `store_lookup_failed.standard_flags` (`store`, `client`, `reason`) after
  the fetch has ended. Google Play has no public API, so Android
  uses `available:` alone.
- **`StandardFlags::ClientStatus.for(client, group:)`** and the
  `StandardFlags::ClientStatus::Controller` mixin
  (`standard_flags_client_status group:, max_age:`; action `client_status`),
  for `GET /client/status`, routed before sign-in. It answers `{status,
  platform, version, min_version, recommended, enforce_at, store_url}` with
  `status` one of `ok`, `upgrade_recommended`, `upgrade_required` or
  `unknown` (an unknown platform or version is never told to upgrade),
  `Cache-Control: max-age=60, private` and a Vary on the client headers.
  A prerelease of exactly the minimum or recommended version meets it.
  Works on API and Base controllers.
- **426 guard.** `requires_client_version only:, except:, group:, with:, override:` on
  `StandardFlags::Controller` answers 426 `client_upgrade_required` through
  `with:`, `config.controller_responder` or a JSON:API body with `meta:
  {min_version, store_url}` (always JSON, whatever the Accept header),
  handing responders a `StandardFlags::Controller::UpgradeDenial`.
  One guard per controller hierarchy: a second declaration (in the class or
  under an inherited one) raises `ConfigurationError` unless it passes
  `override: true`; `skip_client_version_check only:, except:` narrows an
  inherited guard. Builds in their grace window pass; unknown versions pass
  unless `config.require_client_version = true`. The guard, the status
  endpoint and the flag guards read the same client
  (`standard_flags_upgrade_client`): the client the request context names,
  whole, else the X-Client-* headers' client, whole. `StandardFlags::ClientUpgradeRequired` can be raised by app code
  and is answered the same way, even past an app's later `rescue_from
  StandardError`.
- **Compatibility windows.** `compat :k, until_clients: { platform =>
  "version" }`. With `config.track_compat = true` (off by default; needs
  runtime rules), each evaluation counts a hit per platform, and the oldest
  client version for allowlisted platforms (a hint from untrusted headers;
  it starts over after 14 idle days). Counts are written behind to the new
  `standard_flags_compat_stats` table: never during an evaluation, at most
  once per `evaluation_tracking_interval` per process, failed writes
  included (one `compat_tracking_failed` event per interval, reported once
  per process). Every successful write refreshes each window's tracking
  marker (first seen, last flushed), at least once per interval. Operator
  reads don't count; a forked child drops inherited counts. `flags:stale`
  says a window can be removed only after 14 days of tracking, a successful
  write within 2 days, 14 days without hits, and once it has passed on every
  listed platform; it says "not enough data" or "tracking unhealthy since"
  otherwise.
  `Diagnostics.report[:compat]` and the MCP `get_flag` tool (for compat flags
  with a window) show the counts, `tracking_since` and `last_flushed_at`. Stores gain
  `record_compat` and `compat_stats` (nil from stores that don't keep them).
- The migrations generator writes a second, additive migration,
  `create_standard_flags_compat_stats`. Rerunning it adds only what is
  missing: a migration is skipped when its file exists or its table already
  exists in the database (`--no-check-tables` skips that check). The runtime
  store's readiness doesn't depend on the new table.
- `conformance/wire/client_status.json` (scope `wire`, suite
  `client_status`): recognised platforms, registry, header values and today
  in, the status payload out, for client libraries' upgrade-state parsing.
  `conformance/upgrade/client_status_server.json` (scope `server`) adds ENV
  pins and store lookups.
- **Manifest version 2.** `standard_flags:manifest` writes `"version": 2`:
  a top-level `audiences` map (`{ name => { "public" => bool } }`), each
  flag's `audiences` as `{ audience => [every wire name] }`, `min_client`
  (always present), `permanent` (kinds `flag` and `mode`), and `remove_by`
  and `final` when declared. Tombstones with deprecated wires carry `serve`,
  `until` and `until_clients`. A top-level `clients` object holds the client
  registry as declared in code (platform, group, min_version, since, grace in
  days, recommended, available, store_url, and whether a `store_lookup` is
  configured); ENV pins and lookup answers never appear. `owner:` and `description:` are deliberately
  left out. The schema ships as `conformance/schema/manifest.schema.json`.
  `StandardFlags::Tooling::Manifest.read` reads version 1 and 2 files. It
  refuses what the schema rejects, plus a non-integer version, non-calendar
  dates and a wire listed twice for one audience. `#digest` is the SHA-256
  of the canonical render. The JSON layout is pinned by explicit generator
  options.
- **`standard_flags:manifest:check BASE= [BASE_OPTIONAL=1]`** for server
  CI (`StandardFlags::Tooling::ManifestCheck`).
  - Exit 1 when the committed manifest is stale or missing (CRLF line
    endings and trailing newlines are tolerated), with the changes listed
    per flag and tombstone.
  - Exit 2 when the contract breaks: a wire the baseline told an audience is
    gone and no tombstone still serves it (`until:` today or later, UTC); a
    wire changed type; or a public audience serving wires became private.
  - Exit 2 too when `BASE` is missing or unreadable (a stale committed file
    is still reported), or when a manifest can't be read. `BASE_OPTIONAL=1`
    forgives only a `BASE` file that doesn't exist.
  - Without `BASE` the committed file is the baseline, with a warning.
  - A deprecated wire past its `until:` may be dropped. An earlier `until:`
    is a warning, and so is a new wire whose Kotlin name is an existing
    wire's.
  - The README has a CI snippet that fetches the base ref explicitly.
- **`standard_flags:kotlin`** (`config.kotlin_path`, default
  `config/StandardFlags.kt`; `config.kotlin_package`, default none) writes
  plain Kotlin with no dependencies:
  - `StandardFlagsManifest` (`VERSION` and `SHA256` of the manifest);
  - `FeatureType`;
  - per audience, `enum class <Audience>Feature(val wire: String, val type:
    FeatureType)` in wire-name order with `fromWire`, with deprecated static
    wires marked `@Deprecated`;
  - per mode or experiment exposed to any audience, `enum class
    <Key>Value(val value: String)` with `fromValue`.

  The generated source is ASCII.

  Names are stable across regenerations: the task keeps every entry name the
  existing file has (`Kotlin.new(previous:)`) and names only new wires and
  values. A new name never fails on a clash:
  - when wires of one audience map to the same name, the spelling that
    already is the name (snake_case, else SCREAMING_SNAKE_CASE) keeps it,
    unless an existing wire holds it, and other spellings get a suffix from
    the SHA-256 of their exact spelling;
  - when values of one flag do, later ones get the first free `_2`, `_3`, …

  `Tooling::Kotlin::NameClash` is left for clashing type names and
  non-identifiers. An invalid package name raises `ConfigurationError`.
- **TypeScript:** `standard_flags:typescript` adds a `<Audience>Wire` union
  per audience (deprecated static wires included), `WiresByAudience`, and
  the OFREP types: `OfrepEvaluationRequest` (`appVersion` or `app_version`), `OfrepEvaluationSuccess`,
  `OfrepEvaluationFailure`, `OfrepEvaluation`, `OfrepBulkResponse`,
  `OfrepFlagNotFound`, `OfrepInvalidContext`, `OfrepReason`,
  `OfrepErrorCode` and `OfrepBulkResponseByAudience`. The existing
  interfaces and types are unchanged.
- **Conformance:**
  - `conformance/wire/manifest_check.json` (suite `manifest_check`, scope
    `wire`, 26 cases). Each case takes a committed and a current manifest
    plus today's date. It expects `invalid` (naming the manifest to refuse),
    or ok/stale/breaking with removed wires, type changes and audiences made
    private. A client's contract check shares these semantics.
  - `conformance/wire/client_state.json` gains strict-JSON cases: unquoted
    literals, single quotes, unquoted keys, malformed numbers, trailing
    commas, raw control characters, invalid escapes, and nesting beyond the
    new `limits.max_nesting` (100), and lone or reversed surrogate escapes. It
    also gains a version rule: a
    `metadata.version` is kept only when it is printable ASCII without a
    space or `"`.

### Changed

- The committed manifest's format is version 2. Regenerate it after
  upgrading (`bin/rails standard_flags:manifest`). A tool that read version
  1's `audiences` (`{ audience => first wire }`) or `wires` now reads
  `audiences` (`{ audience => [wires] }`). `standard_flags:manifest:check`
  reads a version 1 file, reports it stale, and still checks its wires.

## [0.3.0] - 2026-11-25

### Added

- **Client context.** `StandardFlags::Client` (platform, version, build), a
  frozen Hash subclass, so `context.client` keeps 0.2.2's Hash reads, with
  typed readers. `Client.from_headers(headers)` reads `X-Client-Platform`,
  `X-Client-Version` and `X-Client-Build` (`config.client_headers`); the
  platform is downcased and must be in `config.client_platforms` (default
  android, ios, web, desktop), the version must parse and the build must be
  1 to 18 digits. A bad version or build is dropped; a bad platform becomes
  `"unknown"`, which fails every platform-scoped rule condition. Each emits
  `client_invalid.standard_flags`; nothing raises (invalid UTF-8 included)
  or reports. No headers gives an empty client, which rules read as 0.2.2
  read an empty client.
- `StandardFlags::Controller` reads the headers once per request
  (`standard_flags_client`; empty when there is no request) and evaluates
  guards and payloads for `standard_flags_context` plus that client, unless
  the context already names one. `standard_flags_request_context` and
  `standard_flags_reader` give actions the same context.
  `config.read_client_headers = false` opts out.
- `Context.wrap(value, client:)` and `Context#with_client`, so `for:` can
  carry a client. Jobs' `requires_flag` takes `client:` (a value or a lambda
  run in the job), and the MCP tools take `client:`
  (`StandardFlags::MCP.tools(client:)`).
- **Versions and portable ranges.** `StandardFlags::Version` (SemVer 2.0 with
  `MAJOR.MINOR` and `MAJOR` shorthands, SemVer precedence, build metadata
  ignored) and `StandardFlags::VersionRange`: space-separated comparators
  (`>=`, `>`, `<=`, `<`, `=`), all of which must hold, with `||`
  alternatives, e.g. `>=1.4.0 <2.0.0 || =0.9.5-beta.1`. Kotlin and
  TypeScript clients can implement the same syntax.
- **Build conditions.** Runtime rules take `conditions.builds`
  (`{ platform => range }` over integers, e.g. `>=120 <200`, as
  `StandardFlags::BuildRange`), checked with version ranges; both must hold.
  `SetConditions` and `Testing.rule` take `builds:`.
- **`StandardFlags::FeatureDisabled`**, a raisable `feature_disabled` with
  the flag's `key`, wire name (`feature`) and `status` (403), and
  `StandardFlags.require!(key, for:)`, which raises it.
  `StandardFlags::Controller` renders it exactly like a `requires_flag`
  denial, through `config.controller_responder` when set, even when the app
  declares `rescue_from StandardError` after the include; a 404 one answers
  like `error: :not_found`.
- **Gated MCP tools.** `StandardFlags::MCP::Gated` gives an app's own tools
  `requires_flag :key` (with optional `for:` and `client:`), in every
  subclass. A call while a flag is off returns
  `{"error":{"code":"feature_disabled",...}}` without running the tool.
  `StandardFlags::MCP.visible(tools, actor:, context:, client:)` leaves such
  tools out of `tools/list`, and `StandardFlags::MCP.call(tool, arguments,
  actor:, context:, client:)` calls with the same evaluation. The gate is
  evaluated once per call, however deep the subclasses. A `FeatureDisabled`
  raised inside any tool becomes that error. The gem's own tools are not
  gated.
- Conformance: `runtime/client.json` (neutral ranges, prerelease ordering,
  shorthand versions, build ranges, no-platform and unknown-platform
  clients; RubyGems cases marked `"scope": "server"`),
  `versions/version_ranges.json` (versions and builds, for non-Ruby
  clients; also run through the server's read path, with the five cases
  where the server's RubyGems fallback differs marked `server_matched`) and
  the server-only `versions/legacy_ranges.json`. Every existing
  runtime case with a version range also runs with the range in canonical
  neutral form.
- **Client delivery.** `StandardFlags::Delivery.build(audience, context)`
  returns OFREP evaluation entries (`key` = wire name, `value`, `variant`,
  `reason`; OFREP's `errorCode`/`errorDetails` for a flag whose evaluation
  failed) for every wire the audience is told about, plus tombstones'
  static wires, and an ETag: the SHA-256 of the audience and the canonical
  JSON of the entries, never the config revision. No flag keys, rule IDs,
  env var names, unit keys or unexposed flags.
- **OFREP endpoint mixin.** `StandardFlags::OFREP::Controller`
  (`ActionController::API`, or `::Base` with an explicit
  `csrf: :skip | :protect`; leaving it out raises
  `StandardFlags::ConfigurationError`) with `standard_flags_ofrep audience:`
  serves `ofrep_evaluate_flags` (bulk, with ETag, 304 on If-None-Match,
  `Cache-Control: no-cache, private` and a Vary on Authorization and the
  client headers) and `ofrep_evaluate_flag` (one wire, with a strong ETag;
  404 FLAG_NOT_FOUND for anything the audience isn't told). The app draws
  the routes and authenticates. Units come from `standard_flags_context`,
  never the body's `targetingKey`; the body only adds client attributes,
  headers win, and with `read_client_headers` off neither counts. Before
  Rails parses anything, the mixin answers a non-JSON Content-Type 415 and
  an oversized (64 KiB, bounded read), non-UTF-8 or malformed body 400
  INVALID_CONTEXT, outside the rescue chain. Validated against the OFREP
  OpenAPI document 0.4.0.
- **Embeds.** `StandardFlags.payload(audience, for:, client:, format: :ofrep)`
  and `standard_flags_payload(audience, format: :ofrep)` return the bulk
  body (`{ "flags", "metadata" => { "version" => etag } }`) for bootstrap
  responses, device check-ins and MCP whoami. The flat format stays the
  default.
- **`expose:` aliases.** An audience may list several wire names for one
  flag (`expose: { mobile: %i[chat_enabled insights_enabled] }`), each
  serving the same evaluation. `Definition#wire_names`, `Registry#wires`.
  The manifest keeps `audiences` (first wire, as in version 1) and adds
  `wires` for flags with aliases; the TypeScript interfaces list every alias.
- **`min_client:`** (`{ platform => "version" }`) leaves a flag out of
  OFREP payloads for clients on a listed platform below the minimum, of
  unknown version, or with no (or an unrecognised) platform. Refused on a
  kill switch, which must reach every client.
- **Deprecated wires.** `tombstone ..., serve: { audience => { wire =>
  value } }, until: "YYYY-MM-DD", until_clients: { platform => "version" }`
  keeps a removed flag's client wires answering a static value (reason
  STATIC) through `until:` (required; a UTC date), and only for clients
  below `until_clients:`. `flags:stale` lists a `serve:` block past
  `until:` as removable. The manifest doesn't list tombstones' static wires
  or `min_client:` yet: the version 2 manifest (next release) adds both.
- **`config.audiences`**: the audiences an app serves (an Array, or a Hash
  with `public:` and `unit:`). When set, undeclared `expose:`/`serve:`
  audiences fail boot. A `public: true` audience is the only kind an
  `anonymous: true` OFREP controller serves, evaluated with no actors
  (`StandardFlags::AnonymousContext`; runtime rules skip segments for it),
  the audience's `unit:` keyed by the body's `targetingKey` (use random,
  unguessable install IDs: pre-auth answers are public). A public flag whose
  rule has members or cohorts logs `public_targeting.standard_flags` when
  rules load and shows in the diagnostics.
- `Client.from_context(fields)` checks OpenFeature context fields like
  headers; the OpenFeature provider and the OFREP body share
  `Client::CONTEXT_FIELDS`.

### Changed

- **The conformance suite moved to a top-level `conformance/` folder and
  ships in the gem**, with a JSON Schema (`conformance/schema/fixture.schema.json`)
  every fixture validates against and a README. Each file is tagged `suite`
  and `scope` (`server` or `wire`). New wire suites: `wire/delivery.json`
  (context in, OFREP entries and ETag out) and `wire/client_state.json`
  (payloads in, client reads out), which Kotlin and TypeScript clients can
  run without Ruby.

- Client conditions in runtime rules compare with `StandardFlags::Version`
  and `VersionRange`. Ranges stored by 0.2.x that only RubyGems can read
  evaluate exactly as `Gem::Requirement` did: translated where the neutral
  syntax can hold them (`~> 1.4` reads as `>=1.4.0 <2.0.0-0`, so
  `2.0.0-beta.1` still misses it), and evaluated by RubyGems otherwise
  (`>= 1.4.0.1`, and any prerelease operand such as `= 1.4.0.beta`, which
  RubyGems orders differently). A string valid in both syntaxes
  (`>= 1.4.0`, `>= 1.0.0-alpha`) is read as neutral, so SemVer client
  versions compare by SemVer. A client version outside SemVer (`1.4.0.1`,
  `1.4.0.beta`, a `Gem::Version`, a Float) is still read by RubyGems against
  any range RubyGems can read. Ranges only the neutral syntax can read
  compare SemVer only.
- Deliberate: build metadata in a client version passed in a context's
  client Hash is ignored, as SemVer says, so `version: "1.4.0+381"` now
  meets `~> 1.4` and `>= 1.4`; 0.2.2 refused it. The header path accepts it
  too.
- `SetConditions` stores version ranges in the neutral syntax where it can:
  a neutral range as given, a RubyGems one translated (`">= 1.4, < 2"` is
  stored as `">=1.4.0 <2.0.0"`), and one the neutral syntax can't hold as
  given.
- `Context.wrap(value, client: {})` leaves the context's client as it is,
  as `client: nil` does.
- `requires_flag` denials' `feature` is always a String.
- README: the header, results, roadmap and health-check notes describe
  0.2.2 rather than 0.1.0.

### Removed

- `StandardFlags::Operations::SCOPES`, an unused constant. The scopes are
  the strings `config.authorize` receives.

## [0.2.2] - 2026-11-23

### Changed

- **`SetValue` on a draft rule starts it.** A draft serves the code default,
  so setting a value on a flag nobody had touched (through `SetValue`,
  `flags:set` or the MCP `set_flag_value` tool) used to succeed and change
  nothing until someone also ran `Start`; "set the kill switch off" did
  nothing. Now `SetValue` with a value on a draft rule, including the one it
  creates on first use, moves it to running in the same write: one
  transaction, one revision, one `standard_flags.flag.value_set` event and
  audit row whose before and after show both the status and the value. The
  running rule is checked as `Start` checks it; a failure fails the whole
  operation with `:invalid` and changes nothing. The Result's value, the
  event and the audit row carry `started: true`; no separate `started` event
  is published. Clearing the value (`nil`) never starts a rule.
- **`SetValue` on a paused rule warns.** The rule stays paused and the value
  is stored; `StandardFlags::Result#warnings` (new, empty by default) carries
  `rule is paused; the value is stored but not served until Start`. A stopped
  rule keeps its existing behaviour.
- `flags:set` prints `started` or the paused warning, `set_flag_value`
  returns `started` and any `warnings`, and the admin generator's flash
  shows them. Ramp, SetVariants, SetConditions, member and cohort changes on
  a draft still leave it a draft, and Restore still puts back exact statuses.

## [0.2.1] - 2026-11-23

### Fixed

- **Booting with standard_health 0.9 loaded first.** The standard_health load
  hook was registered before `StandardFlags.registry` was defined; standard_health
  0.9 runs its hooks at require time, so the hook fired mid-require and the app
  failed to boot with `undefined method 'registry'`. The hook is now registered
  at the end of `standard_flags.rb`.

## [0.2.0] - 2026-11-23

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
- **OpenFeature provider (optional).** `require "standard_flags/open_feature"`
  defines `StandardFlags::OpenFeature::Provider` for the `openfeature-sdk`
  gem, which the app brings (it is not a dependency; requiring the file
  without it raises a `LoadError` that says so). Booleans answer
  `fetch_boolean_value`; modes and experiments answer `fetch_string_value`.
  Other pairings return the caller's default with `TYPE_MISMATCH`, and
  unknown keys return it with `FLAG_NOT_FOUND`, even when strict. Reasons and
  error codes map one to one, `ENV_PIN` and `KILL_SWITCH` pass through, and
  `kind`, `rule_id` and `source_env_var` go in `flag_metadata`. The
  evaluation context maps to a `StandardFlags::Context`: `targeting_key` and
  unit-named fields are unit keys, used as given (no `from:` or `key:`);
  `platform`, `appVersion`/`app_version` and `build` become the client. Only
  the flag's own unit key (or `targeting_key`) must be a scalar; other units'
  non-scalar fields are dropped. `env` is ignored unless the provider is built
  with `allow_env_override: true`. The segment resolver receives keys, not
  records, under OpenFeature.
- **Bounded report registry.** The once-per-process report memory holds at
  most 1,000 tokens. Past that it stops recording (and reporting) new ones
  and emits one `report_registry_full.standard_flags` notification, so
  distinct unknown keys can't grow memory without limit.
- **Conformance** fixtures for runtime rules
  (`spec/fixtures/conformance/runtime/`), and a Postgres CI job that runs the
  database specs, including `Bucket.v2` against `Bucket.sql_v2`.
- **Write path.** `StandardFlags::Operations`: `Start`, `Pause`, `Stop`,
  `Ramp`, `SetVariants`, `SetValue`, `SetConditions`, `AddMembers`,
  `RemoveMembers`, `CreateCohort`, `ArchiveCohort`, `AttachCohort` and
  `DetachCohort`, each called as
  `.call(key_or_cohort, actor:, reason:, expected_revision: nil, **args)` and
  returning a `StandardFlags::Result` (`success?`, `value`, `errors`, `code`).
  Each authorises through `config.authorize` (scopes `flags:read`,
  `flags:write`, `flags:ramp`; the default allows only
  `StandardFlags::Actor.system` actors), refuses unknown, tombstoned and
  ENV-pinned flags (`:pinned_by_env`, naming the variable), and writes in one
  transaction: the rule is created on first use (salt and hash version from
  `bucketing:`, else random and v2) and locked, `expected_revision` is
  checked against its `lock_version`, the change is validated (a rule left
  running is checked whole, as `Start` checks it), and the state revision
  moves on. Results carry `revision` (what `expected_revision` is checked
  against: a rule's `lock_version`, the store's revision for cohorts) and
  `store_revision`. A success means the write committed: a transaction that
  a swallowed error aborted fails with `:store_error`. Locks are taken in one
  order (owner, cohorts by id, memberships, state row). `CreateCohort` on a
  taken key, even a concurrent one, fails with `:already_exists`.
  `AttachCohort` and `DetachCohort` authorise the cohort as well as the flag.
  `config.actor_resolver` defaults to `Current.user`.
- **Validation on write**, with configurable limits: `max_members` (10,000
  live members per rule or cohort), `max_keys_per_operation` (1,000),
  `max_cohorts_per_rule` (20) and `max_conditions_bytes` (64 KB).
- **Audit.** Every operation records the actor, the reason and the full rule
  or cohort state before and after, and publishes
  `standard_flags.flag.*` / `standard_flags.cohort.*`
  (`StandardFlags::Events.auditable`) plus `change.standard_flags`. With
  standard_audit loaded, one audit row per change, in a savepoint inside the
  write, through its subscriber when the app subscribes to the events, else
  through `StandardAudit::Operation#audit!`; `raise_on_audit_write_error`
  fails the operation on either path. Everything else (the events when
  standard_audit doesn't need them in the transaction,
  `change.standard_flags`, notifiers, cache expiry) runs after the commit.
  Membership changes record the unit, the value and counts, never a unit
  key, and memberships are inserted with bound values, never inlined SQL.
- **Soft-deleted memberships and purge.** `RemoveMembers` sets `removed_at`;
  `flags:purge` and `StandardFlags::PurgeJob` delete removed and expired
  memberships older than `config.membership_retention` (90 days), locking
  the rules and cohorts it recounts first.
- **Rake tasks** `flags:show`, `flags:set`, `flags:ramp`, `flags:start`,
  `flags:pause`, `flags:stop`, `flags:members:add`, `flags:members:remove`
  and `flags:purge`, each with a required `REASON=`, run as the system actor.
- **`last_evaluated_at` write-behind.** Each process records the flags it
  evaluates and writes them when a unit of work ends (the executor's
  `complete` hook), at most once per `config.evaluation_tracking_interval`
  (an hour) per process, in one `UPDATE` that skips locked rows and leaves
  `lock_version` and `updated_at` alone. Never during an evaluation or
  inside an open transaction; `config.track_evaluations = false` turns it
  off.
- **`flags:stale`** also lists rules at 100% or stopped for 30 days, rules
  not evaluated in 14 days, rules for undeclared or tombstoned keys, and
  memberships due for purge.
- **Revisions never repeat.** `standard_flags_state.revision` is a
  `bigserial`, and every write sets it to the sequence's next value
  (`StandardFlags::Runtime.bump_revision!`), so a revision taken by a write
  that rolled back is never committed again for different rules; a process
  that loaded the rolled-back rules reloads at its next check. A missing
  state row (a database built from `schema.rb`) is created by the next
  write; until then the revision reads as none, every check reloads, and the
  health check warns.
- **Conformance** fixtures for the write path
  (`spec/fixtures/conformance/operations/`).
- **Operator tools (`StandardFlags::MCP`).** `list_flags`, `get_flag`,
  `start_flag`, `pause_flag`, `stop_flag`, `ramp_flag`, `set_flag_value`,
  `list_members`, `add_members`, `remove_members`, `list_cohorts` and
  `get_cohort`: plain objects with `name`, `description`, `input_schema` and
  `call(arguments, actor:)`, returning JSON-safe Hashes or
  `{ "error" => { "code", "message" } }`, with no MCP framework dependency.
  Reads need `flags:read`, filter cross-references (a cohort's attached
  flags, a flag's cohorts) the same way, and never mark a rule as evaluated;
  writes go through the operations and need a reason. `get_flag` names an
  ENV pin's variable, never its value. Unit keys are masked (`•••4567`)
  unless `list_members` is called with `reveal: true`, a reason and
  `flags:write`; a reveal publishes and audits
  `standard_flags.members.revealed` with counts only. `get_flag` with a
  `unit_key` is a reveal too (`flags:write`, a reason,
  `standard_flags.flag.probed`). Both fail closed under standard_audit's
  `raise_on_audit_write_error`, including when its subscriber would swallow
  the failure. One tool instance can serve concurrent calls from different
  actors.
- **Admin page generator.** `bin/rails g standard_flags:admin` writes a
  controller (index, show, one action per operation; configurable base class,
  path and signed-in-user method, answering 401 when nobody is signed in),
  routes, and two Inertia pages in plain markup typed from the generated
  TypeScript. Unit keys are posted as `unit_keys`, which Rails' default
  parameter filter keeps out of logs. Pinned flags are read-only, labelled
  "Pinned by environment (VAR)".
- **TypeScript** output adds `FlagKey`, `FlagValues` and the shapes of the
  MCP tools' results (`FlagList`, `FlagDetail`, `FlagMemberPage`,
  `FlagAuditEntry`, ...).
- **Restore.** `StandardFlags::Operations::Restore` and `flags:restore AT=
  [KEYS=] [APPLY=1] REASON=` put rules (from standard_audit's audit log) and
  memberships (from the memberships table) back as they were at a past time:
  a dry run by default; applied as the system actor, each flag (settings,
  cohorts, members) and each cohort's members in one write with one
  revision bump and one `standard_flags.flag.restored` /
  `standard_flags.cohort.restored` row, cohorts first, removals before
  additions, expecting each rule's planned revision, with partial failure
  reported per target. Skips flags with no audit history at T, pinned flags
  and times older than `config.membership_retention`; `AT=` must name its
  zone.
- **Operator store reads.** `Store#members` (a page of an owner's
  memberships) and `Store#members_at` (as of a time), on both stores;
  `StandardFlags::AuditTrail` reads rule history and recent entries from
  standard_audit's `audit_logs`; `Registry#with_unit_key`.
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

- **A changed membership is versioned.** `AddMembers` on a live member with
  a different value or expiry marks the old row removed and inserts a new
  one (re-adding it unchanged writes nothing), so Restore can read the value
  a member had at a past time. Purge deletes the old rows after the
  retention as usual.
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

### Changed

- **`forbidden_in:` guards can't be relaxed by a context environment.** A
  flag is forced off when either the context's `env` or the process's own
  environment (`registry.current_env`) is forbidden. Before, a
  `Context.new(env:)` naming an allowed environment skipped the guard.

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
