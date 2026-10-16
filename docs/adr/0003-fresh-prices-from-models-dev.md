# ADR-0003: Fresh `{miss}` prices from models.dev (opt-in)

## Status

Accepted — 2026-10-16.

## Context

`{miss}` multiplies the context by the base input price of the model. The
prices are a `case` in `statusline.sh`, copied by hand from the Anthropic
pricing page. The table drifts: a new model gets the newest price of its
family until a Burnbar release, and a new family gets no price at all
(`⚠ unknown model`). PR #2 and PR #3 (by an external contributor) showed the
drift, and #3 proposed a daily download from models.dev.

The statusline JSON has no price. The Anthropic Models API needs an API key,
which a statusline must not ask for. models.dev is a community catalog,
without authentication, with per-provider prices and the long-context tiers.

Rejected alternatives:

- **A CI job that compares the table with models.dev**: no runtime cost, but
  the user gets the fix only with a release.
- **PR #3 as it is**: one `jq` per tick (+2 forks every second), on by default,
  and it keeps the cache-write and cache-read prices, which `{miss}` no longer
  needs.

## Decision

- Opt-in: `BURNBAR_FRESH_PRICES=1`. Without it, Burnbar makes no
  request to models.dev.
- A background job downloads the catalog once a day, only when the format uses
  `{miss}` (or `{next}`), and keeps the `.anthropic.models` input prices, keyed
  by `_model_key`.
- The hot path reads the cache with `read` builtins (zero forks) and overrides
  the built-in table on a hit. The table stays the fallback.
- A failure keeps the lock: the next attempt waits 6 hours. A cache older than
  7 days is ignored.

## Consequences

- A new model gets its price the day models.dev lists it, without a release.
- The prices are as correct as models.dev. A wrong entry there shows a wrong
  `{miss}` for at most a day after the fix. Only `{miss}` uses them: `total`
  comes from Claude Code.
- One download per day per machine (~6 MB, ~0.5 MB compressed), and models.dev sees the request.
- Bedrock and Vertex sessions still get the Anthropic API price, as before.
