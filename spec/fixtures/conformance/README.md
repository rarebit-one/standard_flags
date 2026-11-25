# Conformance fixtures

The evaluation contract as data. The Ruby suite runs every file here; other
evaluators run the parts marked portable.

| File | Who runs it |
|------|-------------|
| `*.json` (resolution, guards, legacy env, permanent flags, buckets) | every evaluator |
| `runtime/*.json` | server evaluators; skip cases with `"scope": "server"` |
| `operations/*.json` | write-path implementations |
| `versions/version_ranges.json` | every client and server: the portable version and build range syntax |
| `versions/legacy_ranges.json` (`"scope": "server"`) | the Ruby server only |

## Scope tags

- `"scope": "server"` on a file or a case: it exercises compatibility only
  the Ruby server keeps, namely ranges stored by 0.2.x in RubyGems syntax
  and client versions passed outside SemVer. Other evaluators skip it.
- `"server_matched"` on a `version_ranges.json` case: clients use
  `matched`; the Ruby server's read path gives `server_matched`. These cases
  pass a client version that isn't SemVer (`1.4.0.1`, `01.4.0`) against a
  range RubyGems can also read (`>=0.0.0`). For 0.2.2 compatibility the
  server reads such a version through RubyGems. Only versions an app passes
  in a context's client Hash reach this: client headers drop a version that
  isn't SemVer, so a client never sees the difference.
