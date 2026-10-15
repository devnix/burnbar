# ADR-0002: Billed spend from the claude.ai plan-usage endpoint (replaces ccusage)

## Status

Accepted — 2026-10-15.

## Context

`{monthly}` and `{daily}` came from ccusage: an API-equivalent **estimate**
computed from local transcripts, through a slow `npx` call. It is not what the
account is billed, it misses usage from other devices and products, and it adds a
Node dependency. Enterprise accounts pay per use against a monthly limit;
Pro/Max accounts pay extra-usage credits on top of the plan. Neither figure is in
the statusline JSON (`rate_limits` only has the 5h/7d percentages).

The only source of the billed amount available to a member is
`GET /api/oauth/usage`, the endpoint Claude Code's own `/usage` screen reads,
authenticated with the OAuth access token in `$CONFIG_DIR/.credentials.json`. It
is **undocumented**. Its `spend` block (`used`, `limit`, `currency`, `enabled`)
holds the billed spend of the billing period. It has no per-day figure:
`extra_usage.daily` exists but was `null` on both accounts tested.

Rejected alternatives:

- **Keep ccusage as a fallback**: the maintainer wants a replacement, not a
  second source.
- **Admin API `cost_report`** (`bucket_width=1d`): exact per day, but needs an
  organization admin key, which a member or a personal account does not have.
- **A mod tool (`$.session.usage()`)**: only percentages and the session's
  estimated cost.
- **A separate `{spend}` tag**: rejected in favor of keeping `{monthly}`/`{daily}`.

## Decision

- `{monthly}` = the endpoint's billed spend, with the plan's limit as the bar
  (`€0.00/€50` on a Pro plan without credits).
- `{daily}` = the latest reading minus the last reading taken before today's
  midnight; reset to zero when the amount goes down (new billing period).
- ccusage is removed.
- Background fetch every 5 minutes, only when the format uses either tag. Any
  failure keeps the lock, so retries wait 5 minutes. Readings older than 1 hour
  are hidden. Read-only use of the token: Burnbar never refreshes it.

## Consequences

- Real billed spend, across all products (Claude Code, chat, Cowork), for every
  account that has a credentials file.
- `{daily}` is approximate: spend between the last reading of the previous day
  and midnight lands on today; with no reading since yesterday, today starts at
  the first reading.
- The endpoint can change or disappear without notice; both tags then go empty.
- macOS keeps the token in the login Keychain. Burnbar reads it with `security`,
  using Claude Code's service naming (a hash suffix for a non-default config
  dir). If Claude Code changes that naming, both tags go empty on macOS.
- The statusline sends the user's OAuth token to `api.anthropic.com` every
  5 minutes while either tag is in the format.
