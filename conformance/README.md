# standard_flags conformance suite

These JSON files are the cross-language contract for standard_flags. The
Ruby gem runs every one of them. Client libraries (Kotlin, TypeScript) run
the `wire` ones. The suite ships inside the gem (`conformance/` in the
installed gem's directory). It is fixture format version 1.

Every file validates against [`schema/fixture.schema.json`](schema/fixture.schema.json)
(JSON Schema 2020-12). Each file has a `description`, a `suite`, which picks
the case shape, and a `scope`:

- `server`: ENV pins, legacy variables, runtime rules, the write path,
  bucketing and RubyGems-syntax ranges. Only server evaluators run these. Clients never evaluate rules.
- `wire`: what crosses the network and what a client does with it. Client
  libraries run these too.

A case may carry its own `scope`, which overrides its file's. In
`runtime/client.json`, cases marked `"scope": "server"` exercise compatibility
only the Ruby server keeps (RubyGems-syntax ranges stored by 0.2.x, client
versions passed outside SemVer).

| File | Suite | Scope | In → out |
|---|---|---|---|
| `resolution.json`, `guards_and_errors.json`, `legacy_env.json`, `legacy_exact.json`, `permanent_flags.json` | `evaluation` | server | registry, environment, env vars → value, variant, reason, error code, deciding variable |
| `runtime/*.json` | `runtime` | server | stored rule, cohorts, memberships, context → evaluation and `rule_id` |
| `operations/write_path.json` | `operations` | server | operations applied in order → evaluations |
| `bucket_vectors.json` | `bucket_vectors` | server | salt, unit key, decision → bucket |
| `versions/version_ranges.json` | `version_ranges` | wire | version or build, neutral range → matched |
| `versions/legacy_ranges.json` | `legacy_ranges` | server | RubyGems range stored by 0.2.x → neutral translation; version → matched (as Gem::Requirement) |
| `wire/delivery.json` | `delivery` | wire | registry, context, client → OFREP entries and ETag |
| `wire/client_state.json` | `client_state` | wire | OFREP payloads → what client code reads |
| `wire/client_status.json` | `client_status` | wire | client registry, X-Client-* header values, today → `/client/status` payload |

## delivery.json: what the server sends

A server runs each case through its delivery builder (in the gem,
`StandardFlags::Delivery.build`) and compares the result with
`{ "flags": expected.flags, "metadata": { "version": expected.etag } }`. A
client library uses each expected body as a golden OFREP payload, for example
to check that its decoder accepts every one.

The rules:

- **Entries.** One entry per wire name of every flag exposed to the audience,
  aliases included. Every alias carries the same evaluation. Entries are
  ordered by `key`, which is the wire name, never the flag key.
- **Success entry.** `{ "key", "value", "reason", "variant" }`. `value` is a
  boolean, or a string for modes and experiments. `reason` is one of STATIC,
  DEFAULT, TARGETING_MATCH, SPLIT, DISABLED, ENV_PIN or KILL_SWITCH.
  KILL_SWITCH is how a client tells "temporarily unavailable" from "not
  available".
- **Failure entry.** A flag whose evaluation failed is OFREP's
  evaluationFailure: `{ "key", "errorCode", "errorDetails" }`. `errorCode` is
  PARSE_ERROR, TARGETING_KEY_MISSING, INVALID_CONTEXT or GENERAL. There is no
  value, so the client uses its code default. One bad flag never breaks the
  others.
- **`min_client`.** The flag is withheld from a client whose platform is
  listed and whose version is below the minimum, or unknown (missing or
  unparseable). It is also withheld from a client with no platform. A
  platform the declaration doesn't list is unaffected. Version precedence is
  SemVer's, so `0.4.0-rc.1` is below `0.4.0`.
- **Deprecated static wires.** A tombstone's `serve` wires are sent with
  reason STATIC and variant `on`/`off` (booleans) or the string itself. They
  are sent through the `until` date, compared with today's date in UTC, and
  stop the day after. Every `serve` has an `until`. A client on a
  platform `until_clients` lists stops receiving them at that version. A
  client with an unknown version, or on a platform it doesn't list, keeps
  receiving them until `until`.
- **What never leaves the server.** Flag keys, rule IDs, env var names, unit
  keys and flags the audience isn't exposed to. No string in `never_on_wire`
  may appear anywhere in a payload.
- **ETag.** The ETag is the SHA-256, in lowercase hex, of the RFC 8785 (JCS)
  canonical JSON of `{"audience": <audience>, "flags": <entries>}`, encoded
  as UTF-8: object keys sorted, no whitespace. Strings may be non-ASCII
  (static values, mode values and variants are free text). They are written
  raw, with only the escapes JCS requires: `"` and `\`, the short forms
  `\b \f \n \r \t`, and other control characters as `\u00xx` in lowercase
  hex. DEL, U+2028 and `/` are left as they are. No numbers occur. A
  serialiser that escapes non-ASCII (Python's default `ensure_ascii`,
  Jackson's `ESCAPE_NON_ASCII`) computes a different ETag. The ETag depends only on what
  the client is told, never on a config revision. Two users who are told the
  same thing share an ETag, and two users told different things never do.
  `etag_same_as` and `etag_differs_from` name earlier cases.

## client_state.json: what a client reads

Each case starts with a fresh client that declares the wire keys it reads,
from the case's `declared` or else the file's:

```json
{ "type": "boolean" | "string", "default": <code default>, "values": [...]?, "ceiling": true? }
```

The case's `steps` then run in order. A step is one of:

- `payload`: an object, which the runner serialises however it likes.
  Payload cases stay well under the limits.
- `raw`: exact UTF-8 bytes, measured against `limits.max_bytes`.
- `not_modified`: a 304.

After each step, compare `accepted`, `version` and every declared key's read
`{ "state", "value", "reason" }`.

**Rejecting a payload.** A client rejects the whole payload, and keeps its
last good one and that payload's version, when any of these hold:

- it is larger than `max_bytes` (a payload of exactly `max_bytes` is
  accepted), or is not JSON (a byte-order mark or trailing bytes make it not
  JSON);
- the top level is not an object;
- `flags` is not an array, or has more than `max_flags` entries;
- an entry is not an object, or has no non-empty string `key`;
- two entries share a key;
- `metadata` is present and not an object.

Before any payload is accepted, every key reads `not_loaded`. Servers never
send an object with a repeated member name, so how a client reads one is not
pinned.

**Accepting a payload.** The client remembers `metadata.version` when it is
a non-empty string, else null, and sends it as If-None-Match next time. A
304 changes nothing, even before any payload. Keys the client doesn't
declare are ignored.

**Reading a key.** An entry's value is *usable* when all of these hold:

- the entry exists;
- it has no `errorCode`, or one that is null;
- it has a `value`;
- the value has the declared type;
- for a string with `values`, the value is one of them.

The read is then:

- **Not usable:** `{ "state": "not_loaded", "value": default, "reason": null }`.
  A missing entry, an entry without a value (OFREP's code-default form), an
  errored entry and a value of the wrong type all mean the code default.
- **Usable boolean:** `state` is `on` or `off` and `value` is the server's
  value.
- **Usable string:** `state` is `loaded` and `value` is the server's value.
- **Ceiling:** a boolean declared `ceiling: true` can only be lowered by the
  server. The value is `default AND server value`. A server `true` against a
  `false` default reads `off`, with value false.
- **`reason`** is the entry's reason when the value read is the server's
  value and the reason is a string, else null.

When a fresh value applies, at launch or live, is the app's policy. It is not
part of this suite.

## client_status.json: upgrade status

A server declares the file's `clients` (its client registry), takes the
case's `client` as the X-Client-Platform, X-Client-Version and
X-Client-Build header values, and answers `GET /client/status` for the
case's `group` (absent: the default group) on `today` (the case's, else the
file's), comparing the body with `expected`. A client library uses each
`expected` body as a golden payload for its upgrade-state parsing.

The rules:

- **The body.** Always the seven keys `status`, `platform`, `version`,
  `min_version`, `recommended`, `enforce_at` and `store_url`, with null for
  anything absent. Versions are canonical SemVer (`0.4` is sent as
  `0.4.0`; build metadata is dropped). `enforce_at` is a UTC date.
- **`unknown`.** No platform, a platform the server doesn't recognise
  (`platform` is then null), or no usable version (`version` null). An
  unknown build is never told to upgrade; the body still carries the
  platform's versions and store URL when the platform is known.
- **The minimum.** A client below `min_version` gets `upgrade_recommended`
  until `enforce_at` (the client's `since` plus `grace_days`) and
  `upgrade_required` from that day on. `enforce_at` is set whenever the
  version is below the minimum. SemVer precedence applies, so
  `0.4.0-rc.1` is below `0.4.0`.
- **Recommended.** At or above the minimum but below `recommended` is
  `upgrade_recommended` with no `enforce_at`. Anything else is `ok`.
- **Store ceiling.** `min_version` and `recommended` are never above the
  newest version known to be in the store (`available`): the body carries
  the capped values, and the comparison uses them.
- **Nothing declared.** A recognised platform with no client in the group
  is `ok`, with null versions.
- **Server-only cases** (`"scope": "server"`) add `env_vars` (the
  `STANDARD_FLAGS_CLIENT_<NAME>_*` break-glass pins) or `store_lookup`
  (client name => what a store lookup answers; null means no answer, so
  `available` applies). Clients skip them.

## versions/version_ranges.json

A version and a range in the neutral syntax, `matched` out; `build_cases`
do the same for build numbers. Also lists
`invalid_ranges` and `invalid_build_ranges`, which every implementation must
refuse. Precedence is
SemVer 2.0 §11. Compare numbers by length, then digit by digit, if your
language lacks big integers. A null version means "no client version" and
never matches. Ranges in RubyGems syntax (`~>`, commas) are not part of the
client contract: `legacy_ranges.json` is server-only.

A case with `"server_matched"` records where the Ruby server reads the same
input differently: for 0.2.2 compatibility it reads a client version that
isn't SemVer (`1.4.0.1`, `01.4.0`) through RubyGems when the range is one
RubyGems can also read (`>=0.0.0`). Only versions an app passes in a
context's client Hash reach that path; client headers drop a non-SemVer
version, so clients never see it. Clients use `matched` and ignore
`server_matched`.
