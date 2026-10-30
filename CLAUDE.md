# Burnbar Development Notes

## Verify Changes

After each change, run `make`. The change is done only on a green `make` (exit 0). On red, fix the cause, or show the failing output to the user. Change a perf threshold only with the user's approval: the thresholds are the regression guard.

`make` mirrors the Linux CI jobs. The macOS job (stock `/bin/bash` 3.2, BSD `date`/`stat`, the Keychain branch) runs only in CI: when a change touches these paths, tell the user.

## Branches and Worktrees

A branch name is `<type>/<slug>`. `<type>` is the Conventional Commits type of the change (`feat`, `fix`, `perf`, `ci`, `docs`, `refactor`, `test`, `chore`). `<slug>` is a short kebab-case name. Example: `perf/bash32-tag-scan`.

`EnterWorktree` with `name` creates the branch `worktree-<name>`, which does not obey this convention. To create a worktree, do these steps:

1. `git fetch origin main`
2. `git worktree add -b <type>/<slug> .claude/worktrees/<slug> origin/main`
3. `EnterWorktree` with `path: .claude/worktrees/<slug>`

## Release Workflow

The plugin version is hardcoded in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` — the plugin system reads it from there, not from the git tag. Always bump the version in both files **before** tagging:

1. Update `version` in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
2. Commit the bump
3. `git tag <version>`
4. `git push && git push --tags`
5. **Publish a GitHub Release — mandatory, not optional.** Every tag MUST have a
   matching Release; a tag without one leaves the public "Latest" stale and
   misleads users. Write the notes (see **Release Notes**), then run `gh release
   create <version> --title "<version>" --notes-file <file> --latest`. (Use
   `--latest=false` only when backfilling an older version.) Never push a tag
   without creating its Release in the same session.

When editing the manifests, change only the `version` line — do not let `jq`
rewrite the file, as it reformats inline arrays (e.g. `keywords`). Edit the line
in place.

### Release Notes

The reader is a user who upgrades from the previous release. `--generate-notes` alone gives a list of PR titles (or only a compare link), so write the notes by hand.

- **Compare the two releases, not the commits.** Read `git log <prev>..HEAD`, then check the facts against `git show <prev>:<file>`. Report the net change: work that was added and removed between the releases does not exist for this reader. Example: `BURNBAR_CACHE_TTL` never shipped, so its removal is not in the 0.3.0 notes, although its commit is `fix!:`.
- **Sections, in this order; omit an empty one:** `Upgrade notes`, `Added`, `Changed`, `Fixed`.
- **`Upgrade notes` come first.** Put here what the reader must do or will notice without asking: a removed tag or variable, a changed default and how to keep the old one, a restart. Always list a new network request or a new use of credentials: what is sent, where, how often, and how to turn it off.
- **One bullet = one effect the user can see.** Name the tag or variable, and link the PR when there is one. Do not name internal functions or files, and do not paste commit subjects.
- **Leave out** CI, tests, internal docs and refactors. Include performance only with a measured number and only when the user can notice it.
- **Thank the co-authors in the bullet.** When a bullet comes from a commit with a human `Co-authored-by` trailer or a superseded PR of another person, end that bullet with `(thanks @<login>!)`, not with a paragraph or a full name at the end of the notes. GitHub notifies that login and lists it on the Release. Get the real login from the PR (`gh pr view <n> --json author`), never from the name or the email. Do not thank AI co-authors.
- **End with** `**Full Changelog**: https://github.com/devnix/burnbar/compare/<prev>...<version>`.

## Hook Output

Claude Code hooks communicate with the user through the JSON they write to stdout.

**`systemMessage`** — displays text directly to the user. Use this for any message the user must see (install notices, warnings). Does not go through Claude.

**`hookSpecificOutput.additionalContext`** — passes context to Claude, which may or may not relay it. Unreliable for critical messages.

Combine both when you need the user to see something and Claude to know about it:

```json
{
  "systemMessage": "Message shown directly to the user.",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Context for Claude."
  }
}
```

## What Does Not Work

- **`stderr`** — suppressed by Claude Code, never reaches the user.
- **`/dev/tty`** — hooks run without a controlling terminal on macOS and Linux.

## Plugin vs. Cache

When launched with `--plugin-dir /path/to/plugin`, `CLAUDE_PLUGIN_ROOT` points to that directory and the hook there runs directly. Changes take effect immediately — no reinstall needed.

## Statusline

Claude Code reads `settings.json` at startup. There is no hot-reload. A restart is required after changing `statusLine`.

### Statusline JSON Input

The statusline command receives JSON on stdin with these fields:

- `cwd` — working directory
- `context_window.used_percentage` — float (e.g. 47.3)
- `context_window.current_usage.input_tokens`, `.cache_creation_input_tokens`, `.cache_read_input_tokens`
- `model.id` — e.g. `claude-opus-4-6` (changes with effort level too, not just model)
- `model.display_name` — e.g. `Claude 4 Opus`
- `cost.total_cost_usd` — cumulative session cost
- `session_id` — UUID, stable per conversation
- `effort.level` — `low`, `medium`, `high`, `max`
- `fast_mode`, `thinking.enabled`
- `rate_limits.five_hour.used_percentage` — % of the 5h plan window consumed (0–100, float)
- `rate_limits.five_hour.resets_at` — epoch seconds when the 5h window resets
- `rate_limits.seven_day.used_percentage` — % of the 7-day plan window consumed (0–100, float)
- `rate_limits.seven_day.resets_at` — epoch seconds when the 7-day window resets

`rate_limits` is **only present for Pro/Max subscribers, and only after the first
API response of the session**. Each window (`five_hour`, `seven_day`) can be absent
independently — extract with `// ""` to tell "absent" from a real `0`. The
`used_percentage` is a snapshot of the last API response (same as the in-app "plan
usage limits" UI); `resets_at` is rendered as a reset clock (`↺HH:MM` for `{5h}`;
`countdown + ↺HH:MM` for `{1w}`). **Staleness (by design, not a bug):** during idle
after a reset, the old % holds and the clock/countdown points at an already-past time
until the next API response refreshes both. Inherent to the source.

### Multi-Session Behavior

Claude Code runs the statusline command **for all active sessions**, not just the current one. The `model.id` in the JSON input alternates between sessions (e.g., sonnet/opus/haiku). Use `session_id` to isolate per-session state — never compare `model.id` across statusline evaluations without session isolation.

### `refreshInterval`

`statusLine.refreshInterval` controls how often (in seconds, 1–60) the statusline command runs. Set to `1` for real-time updates (required for the cache timer countdown).

## Cache Timer Architecture

### Timestamp Files (`~/.claude/.cache-ts-<session_prefix>`)

The timer restarts only on evidence that the cache lives: a main-thread response with `cache_read_input_tokens + cache_creation_input_tokens > 0`. A read refreshes the lifetime too, and the lifetime runs from the **start** of the request (prompt caching docs). A prompt, a tool call or an API error is not evidence.

- Written by the `PreToolUse` (async), `PostToolUse` and `Stop` hooks (`cache-touch.sh`), in the same `jq` pass over the transcript tail as the TTL and the model. The value is the epoch of the request start, not the hook time.
- Request start: Claude Code (2.1.302) writes an `"type":"api-request"` entry (no `isSidechain`) when it sends each request. The hook takes the last one between the parent entry of the first response block (`parentUuid`: the prompt or the tool result) and that block. No request entry → the parent (early by the `UserPromptSubmit` hooks: 1.7 s measured); no parent in the tail → the block (late by the first tokens).
- Blocks of one response share `message.id`: the first block in the file anchors the call.
- The timestamp never moves back: only a newer epoch is written. No evidence → no write.
- Key = first 8 chars of `session_id` (per-session isolation). Hooks use `$CLAUDE_CODE_SESSION_ID`; the statusline uses `${session_id:0:8}` from its JSON input.
- Cleared on `SessionStart`: a new or resumed session shows `--:--` until its first evidence.
- While a request runs, the timer keeps the last evidence: it can be low by the time to the response, and it can reach `00:00` although the request already refreshed the cache. It is never high. On consecutive turns the error is small. No in-flight marker: a `⟳` from `UserPromptSubmit` until the response was tried and removed, because an Esc before the first response block leaves no trace (no hook, and no `[Request interrupted by user]` entry in the transcript, measured on 2.1.314), so the marker stayed up with no request running.
- Subagent events are skipped (`agent_id` in the stdin head, before `hook_event_name`; measured on 2.1.302): the tool hooks also fire inside a subagent, whose cache is separate. While a subagent runs, the main countdown keeps running, because the main cache is not refreshed.
- `PreToolUse` is `"async": true` so that the transcript wait does not delay each tool, and the countdown restarts before a long tool runs. `PostToolUse` is synchronous and reads the same state: it is the fallback for the async hook, and a post-tool hook also stops tools from running detached.
- Cache keepalive (checked in the 2.1.302 binary): interactive sessions with a 1h subscriber TTL send `anthropic-beta: cache-keepalive-2026-09-03` behind the `tengu_sequential_cloud` flag (`touchIntervalSeconds` 30, `activityWindowMinutes` 60). When the server answers `anthropic-cache-keepalive: active`, Claude Code calls `/v1/messages/cache_touch` during idle time, and the transcript does not show it: the countdown would be too low. Measured on an Enterprise account (2026-10-16): flag on, `--debug` shows `[cache-keepalive] response not active`, so no touches.

### TTL Files (`~/.claude/.cache-ttl-<session_prefix>`)

Claude Code picks the cache TTL per user: 1h for subscribers (behind an allowlist and a feature flag), 1h with `ENABLE_PROMPT_CACHING_1H` or a setting, else 5m. The statusline JSON has no TTL: `current_usage` carries only the four token totals, not the `cache_creation` breakdown (checked in the 2.1.301 binary).

- Written by the `PreToolUse`, `PostToolUse` and `Stop` hooks (after each API call, off the hot path): the TTL can drop from 1h to 5m mid-turn (overage). It reads `transcript_path` from the first 8 KB of the hook stdin with a bash regex (`read -n 8192`: `tool_input` can be MBs, and bash reads a pipe byte by byte, ~0.35 s/MB measured), then takes the last `"isSidechain":false` entry with a cache write (1h + 5m tokens > 0) in the last 256 KB of the transcript. `ephemeral_1h_input_tokens > 0` → `3600`, else `300`; no write in the tail → keep the file. Skip the pure reads (`0`/`0`), but take the last write, never a sum: one session mixed 1h and 5m writes.
- Statusline: one `read` of the file (only `300`/`3600` are valid). No valid file → the TTL is unknown: `--:--`, no notification, `{miss}` empty (its write price depends on the TTL). Never a default: a guessed 5m was the bug. There is no override variable: `BURNBAR_CACHE_TTL` was removed, because it hid a real 1h → 5m drop.
- Do not infer the TTL from the auth type or from `rate_limits`: the binary decides it through an allowlist, a feature flag and a "keep 5m" path, so the plan alone does not tell it.
- The colors scale with the TTL (green > 40%, yellow > 20%). The notification fires `BURNBAR_NOTIFY_LEAD` seconds before expiry (default 300), capped at 50% of the TTL: 5:00 on a 1h cache, 2:30 on a 5m cache.
- Expired (`00:00`): the countdown flashes, white on red when the epoch second is even. The statusline runs once per second (`refreshInterval: 1`), so the color alternates with zero forks. SGR 5 (blink) did not show in a test on Claude Code with Ghostty.
- `BURNBAR_CACHE_WIDTH=0` hides the bar: no `_render_bar` call and no leading space. A non-numeric width falls back to 8.
- `PreToolUse` and `Stop` fire before Claude Code writes the response to the transcript (measured: absent at +0 s, present at +0.2 s). The hook reparses every 0.1 s, up to 1 s, until the last main-thread user/assistant entry is an `assistant` entry; then it uses what is there. `PostToolUse` runs after the tool result is written, so it reads the response at once. The wait uses `sleep 0.1`: BSD, GNU and busybox `sleep` take fractions (macOS is checked only in CI).
- Tested by `tests/cache-ttl.sh` (`make test`, `make test-bash32`).
- Not cleared on `SessionStart` (a resumed session keeps its TTL); stale files (>1 day) are cleaned with the others.

### Cache-Miss Cost (`{miss}`, alias `{next}`)

`miss = ctx × price_in × (2 for 1h | 1.25 for 5m)`: the whole context written to the cache again. Only the base input price is needed. The `case` matches the version (specific globs first, `[1m]` suffix stripped); an unlisted version of a known family gets the newest price of that family. Haiku 5.5 has a long-context tier (`price_lc`/`price_lc_in`), chosen in awk from `ctx`. `{next}` was the old "current context at last call's cache split" estimate; it is now an alias, so user formats keep working.

### Fresh Prices (`BURNBAR_FRESH_PRICES`)

Daily refresh, on by default (`BURNBAR_FRESH_PRICES=0` turns it off), of `price_in`/`price_lc`/`price_lc_in` from `https://models.dev/api.json` (ADR-0003). The `case` stays the fallback and still sets `model_family`.

- **Job** `_update_prices`, started by `_spawn_refresh` when the cache epoch is older than `PRICE_TTL` (1 day), only when the format has `{miss}` or `{next}`. It keeps only `.anthropic.models` (other providers list Claude at other prices), the `input` price and the first `tiers[]` entry with `tier.type == "context"`. Each id goes through `_model_key`, so a Bedrock, Vertex, `[1m]` or dated id matches by construction: `_model_key` is defined before the pricing block for this reason.
- **Failure = backoff**, as for the plan spend, but `PRICE_BACKOFF` is a fixed 6 h (the third argument of `_spawn_refresh`, no fourth, so no doubling): the catalog is ~6 MB (~0.5 MB with `--compressed`), and a schema change that the parser rejects would otherwise download it every 5 min. The job writes a `mktemp` file in the cache dir, then `mv`; the lock goes only after the `mv`.
- **Cache** `~/.cache/burnbar-prices`: line 1 = fetch epoch (no `stat` on the hot path), then `key price_in price_lc price_lc_in`. Not per profile: prices do not depend on the account.
- **Hot path**: after the `case`, a `while read` loop over the cache (builtins, zero forks), override on the first valid line of the same key. A hit sets `model_known=1`, so a new family gets a price. A cache older than `PRICE_MAX_AGE` (7 days) is ignored: an old download must not override a newer table from a plugin update.
- `tests/perf.sh` runs with the default (on) and a fresh cache (the fixture model last), and its sanity check expects the cache price, so the fork gate covers the lookup. Functional tests: `tests/prices.sh`.

### Metadata Files (`~/.claude/.cache-meta-<session_prefix>`)

- Key = first 8 chars of `session_id` (per-session isolation)
- Format: `timestamp|model_id|effort_level` (pipe-delimited; `model_id` without `[1m]` except on the 200K models, `none` when absent)
- **Baseline semantics**: model and effort are recorded when the file is created and reset on each new API call (`meta_ts != last`). Between API calls, the baseline is immutable — the alert persists while the current model/effort differs
- Baseline resets with the timestamp, so only on evidence of a cache read or write. The reset tick also evaluates the alert. A prompt to a new model keeps the alert until its response arrives.
- **Baseline model = the model of the evidence call**, not the statusline model at the reset: a switch during a turn changes the statusline model, but the calls already made used the old one. `cache-touch.sh` writes `.cache-model-<key>` as `epoch|model` (`message.model` of the evidence entry), **before** the timestamp, with the same epoch. The statusline reads it only on a reset, and uses it only when its epoch equals `last` and its model differs from the current one (compared by `_model_key`, so `[1m]`, Bedrock and Vertex forms match).
- No `UserPromptSubmit` hook: a prompt is not evidence.
- Only the model comes from the transcript, not the effort: the effort sent (`effort` field) includes per-turn, hook and carried effort and the clamp when thinking is off, so it can differ from `effort.level` for good. An effort switch during a turn is still not caught.
- Known false alert: a server refusal fallback answers with the fallback model, so `⚠ model` shows until the next API call.
- Same-second limit: two hooks in one second give one `last`; the statusline sees one reset.
- Stale files (>1 day) cleaned on `SessionStart` via `find -mtime +1 -delete`

### Model Comparison

The cache belongs to one model version, so Sonnet 4.6 → Sonnet 5.5 is a model change. Compare `model.id`, not the family.

The `[1m]` suffix: on the 200K models with `supports_1m_beta` (Sonnet 4.0/4.5/4.6, Opus 4.6), it sends the `context-1m-2025-08-07` beta and moves the request to the 1M tier: it is part of the key, so a toggle alerts. Not measured (Sonnet 4.6 `[1m]` needs usage credits on a Pro/Max plan). On the native-1M models, it is stripped: measured on Haiku 5.5 (2026-10-16), `[1m]` read 43 K of 43 K. In 2.1.301, `model.id` is the model of the next call: it follows the permission mode (e.g. `opusplan`) and the 200K threshold, not the effort level.

A meta file written by an older Burnbar holds the family (`opus`/`sonnet`/`haiku`/`fable`/`unknown`): it is compared with the family, so an upgrade causes no false alert. The next API call rewrites it with the id.

Alert priority: model first, effort second (only if the model stayed the same).

### Effort Alert by Model (`effort_breaks_cache`)

The effort alert shows only when an effort change rewrites the cache. Claude Code (2.1.301) sends `output_config.effort` at the top level **and**, on the models with the `per_turn_effort` capability (Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5), a per-turn `role: "system"` message with the new effort (beta `per-turn-control-2026-07-01`). With that message, the cache stays.

- Measured with `claude -p --effort low|high --resume` (2026-10-16): Haiku 5.5 read 42 K of 42 K after low→high; Sonnet 5 read 0 and wrote 50 K.
- The `case` on `model_id` lists the models that rewrite the cache: the models that get `output_config.effort`, less the `per_turn_effort` ones. The binary function that sends effort (`Ub()` in 2.1.301) excludes `claude-3-*`, Opus 4.0/4.1, Sonnet 4.0/4.5 and Haiku 4.5, forces `claude-mythos-5` on, and else sends it on first-party: so Opus 4.5 and Mythos 5 are in the list without the `effort` capability. An unlisted model gets no alert, because a new model is expected to have `per_turn_effort`.
- Claude Code turns the beta off with `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`, and off providers other than first-party, Anthropic AWS/Google Cloud, Foundry and Mantle. The statusline checks the env vars it can see (`CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_BEDROCK` without `CLAUDE_CODE_USE_MANTLE`): then every model alerts. Not detected: HIPAA orgs and the server kill switch.
- To update the list: in the binary, read the model registry (`capabilities:[...]` per `{id:"claude-...`) and the function that sends effort (the one with the `claude-mythos-5` special case). Effort sent and no `per_turn_effort` → in the list.

### Notification Files (`~/.claude/.cache-notif-<session_prefix>`)

- Key = first 8 chars of `session_id` (same as timestamp files)
- Stores the cache timestamp (`$last`) for which the notification was already sent
- Prevents repeated notifications: only fires once per cache period when `remaining` crosses the lead time (`BURNBAR_NOTIFY_LEAD`, max 50% of `CACHE_TTL`)
- Cleared on `SessionStart` alongside the timestamp file
- Stale files (>1 day) cleaned on `SessionStart`

### Notification Delivery (`BURNBAR_NOTIFY`)

Uses Claude Code's own notification preference as the primary signal:

1. Read `preferredNotifChannel` from `~/.claude/settings.json`
2. If `terminal_bell` → use BEL
3. Otherwise auto-detect OSC from `TERM_PROGRAM`:
   - **OSC 777** — Ghostty (supports click-to-focus, unlike OSC 9)
   - **OSC 9** — iTerm2, WezTerm
   - **OSC 99** — Kitty (via `KITTY_WINDOW_ID`)
   - **OSC 777** — fallback for other terminals (urxvt, Warp)

Manual override: `BURNBAR_NOTIFY=osc9|osc99|osc777|bell|none`

All sequences write to `/dev/tty` with `2>/dev/null` — silent if unavailable. Claude Code hooks support `terminalSequence` for notifications, but hooks only fire during active use; since the cache counts down during idle, the statusline must emit the notification directly.

### Terminal Discovery

The statusline process has no controlling terminal (`/dev/tty` fails). To deliver OSC/BEL sequences, it walks up the process tree via `/proc/$PPID/fd/1` until it finds a pty (`/dev/pts/*` or `/dev/tty*`). Typically resolves in 1–2 hops (statusline → Claude Code node process → has the pty).

This walk only runs once per cache period (when the notification triggers). The `readlink` + `awk` per hop is negligible for a one-shot event.

Performance: the notification path runs once per cache period (not every second). The `readlink`/`awk` walk and single `jq` call to read `preferredNotifChannel` are acceptable here — they do not affect the per-tick hot path.

## Cost Sparkline Architecture

### Turn Boundary Detection

`cost.total_cost_usd` is only visible to the statusline (hooks don't receive it), and hooks fire on every API call (`PreToolUse`), not per turn. The split:

- **Hook side**: `hooks.json` passes the hook event name as `$1` to `cache-touch.sh`; on `Stop` it writes `~/.claude/.turn-ts-<session_prefix>` (turn marker), before the transcript wait. `PreToolUse` and `PostToolUse` only update the cache state.
- **Statusline side**: when the marker differs from the one stored in `.cost-hist-<key>`, the turn ended — `delta = total_cost_usd - stored_base` is appended to the history, and marker/base are rewritten.

`Stop` as the turn boundary captures the cost of each Claude response immediately (including all tool calls, subagents, and thinking), instead of deferring it until the next `UserPromptSubmit`. Using only `Stop` avoids spurious zero-cost deltas that `UserPromptSubmit` would produce (no work happened since the previous `Stop`).

### State File (`~/.claude/.cost-hist-<session_prefix>`)

Three lines: turn marker (opaque string, `<epoch>-$RANDOM` so two turns ending in the same second still differ), cost baseline (raw float), space-separated deltas (`%.4f`). Rewritten on turn boundaries and once at tracking start to capture the baseline — not on every tick. Cleared on `SessionStart`, stale files cleaned with the other `.cache-*` files.

The baseline is captured eagerly at tracking start (the first statusline tick where no baseline exists yet, before any turn completes), with an empty marker. This makes the **first** completed turn record a real delta (`total - baseline`), so the sparkline appears after the first turn. For a fresh session the baseline is ~0 (so the first turn's full cost is recorded); for a **resumed** session it's the already-accumulated total (so the first post-resume turn measures only its own cost — no spurious giant first bar). The eager write happens at most once until a turn boundary; if a turn boundary is somehow crossed before any tick captured a baseline, the old fallback applies (re-init, no delta — first turn lost).

Robustness invariants:

- **Keep cap**: the persisted delta list keeps `max(32, render_window)` turns, never just the render window — switching to a narrower mode/width must not destroy history.
- **Persist guard**: when a delta was recorded (`spark_record=1`), the file is only rewritten if awk actually produced a history (`spark_newhist` non-empty) — a failed awk/jq on a boundary tick must not wipe the history (same bug class as the notification sentinel).
- **Baseline validation**: a corrupt/empty baseline line is treated as re-init (baseline rewritten, no delta recorded) — otherwise the next delta would swallow the entire session cost.
- **`BURNBAR_SPARK_WIDTH` validation**: empty/zero/non-numeric falls back to 8.

### Rendering

The sparkline always renders at `SPARK_WIDTH` cells — unused cells are padded with `UNFILLED_BG` (grey, same as other bars). Data characters use cyan foreground on the same grey background. This keeps the layout stable regardless of how many turns have been recorded.

**Live turn**: on a tick with no new marker and a valid baseline, `live = total - baseline` is the value the next `Stop` records. When it is ≥ $0.00005, awk appends it to the render array only (`rn = n + 1`; `snew` stops at `n`, so it is never persisted and no file is written on a live tick). It takes part in the window max, so the older bars shrink when it becomes the max. At `Stop`, the recorded delta takes the same index: the braille/octant pairing does not shift. Cost that arrives between turns (after `Stop`) shows as live and goes into the next delta, as before. No separate color: in braille/octant the live column shares its cell with the previous turn. `tests/live-delta.sh` covers it.

The `{delta}` tag shows the last element of the render array as a labeled value (e.g., `delta:$0.0312`): the live turn while it runs, else the last recorded turn. It is output before `spark_newhist` — `spark_newhist` must remain the last field in `read` because it contains spaces.

Levels are quantized in the existing single awk call at the mode's native resolution (`lmax`: 0–8 for blocks, 0–4 per column for braille/octant), scaled to the window max with nonzero deltas flooring at 1, and emitted as a digit string — awk owns all numeric scaling, bash does pure table lookup on the digits. Braille/octant index hardcoded 25-entry tables with `left_level*5 + right_level`:

- **Braille** (U+2800 + column masks) — universal font support, default.
- **Octants** (Unicode 16, U+1CD00 block + classic quadrants/eighth-blocks for the patterns Unicode excluded from it) — solid 2×4 blocks, auto-selected on Ghostty/Kitty (both render them natively without font support).
- **Blocks** (`▁▂▃▄▅▆▇█`) — 1 turn/cell, 8 levels.

The octant table was generated from Unicode 16 `UnicodeData.txt` — the bottom-filled column combos map to a mix of `BLOCK OCTANT-*` (U+1CDxx), `U+1CEA0`/`U+1CEA3` (half-column quarters), quadrants (`▖▗▙▟`), and eighth-blocks (`▂▄▆█▌▐`). Don't try to derive these arithmetically; the codepoint assignment is non-contiguous.

Hot path cost: one `read` per tick for the turn marker plus pure-bash rendering — zero additional forks. The history file is read with `read` builtins and written only on turn boundaries.

## Billed Spend (`{monthly}`, `{daily}`)

Both tags come from `GET https://api.anthropic.com/api/oauth/usage` — the undocumented endpoint behind `/usage` (ADR-0002). It replaced ccusage: Burnbar has no ccusage dependency.

- **Fetch**: `_update_plan_spend`, a background job started by `_spawn_refresh`, every `PLAN_TTL` (300 s), only when the format contains `{monthly}` or `{daily}` and credentials exist. `_read_credentials`: Linux reads `$CONFIG_DIR/.credentials.json`; macOS reads the login Keychain with `security find-generic-password -a <account> -w -s <service>`, using Claude Code's own naming — service `Claude Code-credentials`, plus `-<sha256(dir)[:8]>` when `CLAUDE_CONFIG_DIR` (or `CLAUDE_SECURESTORAGE_CONFIG_DIR`, which wins; empty = no suffix) is set; account `$USER`, or `claude-code-user` when `$USER` has characters outside `[a-zA-Z0-9._-]`. Token: `.claudeAiOauth.accessToken`, skipped when `expiresAt` is past, sent through `curl -H @-` (stdin, never argv — `/proc/*/cmdline` is world-readable).
- **Never refresh the token.** A refresh rotates the refresh token and can log Claude Code out.
- **Failure = backoff.** On any failure (401, 429, network, parse, expired token) the job writes nothing and **keeps the lock**. Removing the lock on failure turns every failure into one request per tick (1 s) — a 429 seen in testing confirmed the endpoint rate-limits. The lock holds the attempts since the last success: `_spawn_refresh` writes `n+1` into it (a builtin `printf`, no fork) before it spawns the job, and skips while the lock is younger than `300 × 2^(n-1)` s, capped at `PLAN_MAX_BACKOFF` (1 h, its fourth argument): 5 → 10 → 20 → 40 → 60 min. A success removes the lock, so the count resets. An empty lock (an older Burnbar) counts as 1 attempt. The 429 gives no help: `retry-after: 0` (2026-10-16, a 429 for more than 1.5 h).
- **Parsing**: `spend.used`/`spend.limit` (`amount_minor` / 10^`exponent`), falling back to `extra_usage.used_credits`/`monthly_limit` (`decimal_places`). Persist guard: the cache is only rewritten with numeric values.
- **Cache** `~/.cache/burnbar-plan-spend-<profile>`: `used|limit|currency|enabled|epoch|day_baseline|day|daily`. One `read` on the hot path — zero extra forks.
- **`{daily}` derivation** (in the job, not the hot path): same `day` → keep the baseline; new day → baseline = previous reading if taken since yesterday's midnight, else the current amount (no history → today starts now). `used < baseline` → new billing period, baseline = 0. Known error: spend between yesterday's last reading and midnight lands on today. On the hot path, a cache whose `day` is not today shows `0.00`.
- **Display**: a reading older than `PLAN_STALE_AGE` (15 min, 2 missed refreshes) is still shown, with a `~` before the amounts (`mo:~$98.33/$400`). It is never hidden: during a long 429, the last reading is better than nothing. The plan limit is the monthly budget; `BURNBAR_MONTHLY_BUDGET` only applies when the plan has none. Currency symbol from the response (USD `$`, EUR `€`, GBP `£`, else the ISO code), shared by both tags.
- Observed shapes (2026-10): Enterprise → `five_hour`/`seven_day` `null`, `spend` in USD with the org's monthly limit. Pro → windows present, `spend.enabled=false` (`out_of_credits`), shown as `€0.00/€50`. `extra_usage.daily`/`.weekly` exist but were `null` on both.
- Tested by `tests/plan-spend.sh` (stub `curl`; never call the real endpoint in a loop: each call uses the quota and makes a 429 last longer).

## Performance

The script runs every 1 second. Minimize subprocess forks.

### Regression test

`tests/perf.sh` runs in `make perf` (your bash) and `make perf-bash32` (bash 3.2 in Docker). It renders a hermetic fixture (every data tag, no network) and fails on: forks per tick (needs `strace`), CPU time per tick against a budget (CPU, not wall time: wall time doubled under load and flaked), and super-linear scaling — 4x longer segments (wider bars, one escape per cell) and 4x more segments (repeated format body). Verified against two mutants: `sed` per segment (67 forks, 70 ms) and the extglob strip (×31 on segment length).

### Patterns That Work

- **Single jq call** with `@sh` + `eval` to extract all fields at once. Use `// ""` or `// 0` before `@sh` to guard against null producing literal `null`. Guard with `jq_out=$(...) && eval "$jq_out"` so jq failures don't eval garbage.
- **Single awk call** for all floating-point computation (bar geometry, cost formatting, token counts). Pass all inputs via `-v` flags.
- **`LC_NUMERIC=C`** before awk to prevent locale-dependent decimal separators.
- **`%.4f`** (not `%s`) for monetary values in awk — `%s` uses OFMT (%.6g) which produces scientific notation for large values and drops trailing zeros.
- **Inline shell arithmetic** for color thresholds instead of calling functions that fork awk per cell. Formula: `$((2*i+1)) -lt $BAR_WIDTH` for 50%, `$((10*i+5)) -lt $((BAR_WIDTH*8))` for 80%.
- **`${var:0:8}`** instead of `printf | cut` (bashism, zero forks).
- **`read -r var < file`** instead of `var=$(cat file)` (no fork).
- **`printf -v var`** instead of `var=$(printf ...)` (bash builtin, no fork).
- **`_epoch var` / `_strftime var fmt epoch`** instead of `date` — `printf '%(...)T'` builtin on bash >= 4.2 (zero forks), `date` fallback on macOS's bash 3.2 (`date -r`, `date -d` on GNU). Never call `printf '%(...)T'` directly: bash 3.2 rejects it.
- **`_vis_width`** for the visible width of a segment (strips the literal `\033[...X` text with parameter expansion, linear in the number of escapes). The `{sep}`/`{wrap}` layout splits the line into segments once and measures each segment once.
- **`$USER`** / **`${HOSTNAME%%.*}`** instead of `whoami` / `hostname -s`.

### Patterns That Don't Work

- **Separate jq calls** per field — each is 2 forks (subshell + jq). 10 calls = 20 forks.
- **Shell functions that pipe to awk** (`cell_bg`, `cell_fg`) called in a loop — up to 90 forks for BAR_WIDTH=30.
- **One `${var//pat/rep}` per tag** over the growing line — quadratic on bash 3.2 (×60 for 4x segments), and on bash ≥ 5.2 an `&` in the value expands to the match (`patsub_replacement`). The tags expand in one left-to-right scan.
- **`tostring` without `@sh`** for numeric jq fields in eval — vulnerable to injection if the field is ever string-typed.

### Benchmark Reference

| Version | Forks | Time/invocation |
|---------|-------|-----------------|
| Original (many jq/awk, cell_bg/cell_fg) | ~150 | ~289ms |
| Optimized (batched jq+awk, inline colors) | ~18 | ~19ms |
| + printf %(%s)T (no date +%s) | ~16 | ~17ms |
| `{sep}` collapse/wrap via `$(printf \| sed)` per separator (regression) | ~56 | ~111ms |
| + `_vis_width`, one measure per segment | ~6 + `_detect_cols` | ~25ms |
| bash 3.2 (macOS): one `date` call per tick, clocks by arithmetic (was 12 forks) | 5 (bash 3.2), 4 (bash 5) | ~55–65ms on bash 3.2 |

## Known Bugs and Fixes

### Model/effort baseline must be immutable

**Bug**: If the meta file rewrites model/effort on every alert detection, the baseline drifts. The alert only shows for 1 tick (detected → meta rewritten → next tick sees no mismatch). Also, switching A→B→A triggers two alerts, even though the user returned to the original.

**Fix**: Baseline model/effort reset only on new API calls (`meta_ts != last`), not on alert detection. Between API calls the baseline is immutable, so the alert persists while the model/effort differs. Sending a message confirms the new model and resets the baseline.

### Notification sentinel written before delivery

**Bug**: Writing the sentinel file before sending the OSC/BEL sequence means a silent delivery failure (pty gone, permission error, swallowed by `2>/dev/null`) permanently suppresses the notification for the entire cache period — the sentinel is already set so subsequent ticks skip delivery.

**Fix**: Set `_sent=1` inside each `case` arm only on successful `printf` (`&& _sent=1`), write the sentinel only if `_sent=1`. `BURNBAR_NOTIFY=none` returns early, before the tty walk, and writes the sentinel there (`tests/cache-ttl.sh` uses it to observe the trigger without a tty).

### `has_cache=1` with an invalid timestamp

**Bug**: If the ts_file exists but contains empty or corrupt content, `last` is forced to 0 but `has_cache` is still set to 1. This renders a phantom 00:00 bar and may write a meta entry with `last=0`, causing spurious model-change alerts on subsequent ticks.

**Fix**: Wrap the elapsed/remaining calculation in `if [ "$last" -gt 0 ]` — only activate `has_cache` when the timestamp is a valid positive integer.

### A 5-minute timer on a 1-hour cache

**Bug**: On a 1h cache, a new session showed `05:00` for its first turns. The statusline fell back to a 300 s TTL when the TTL file was absent. The `Stop` hook read the transcript before the response was in it, so a turn without tools never wrote the file. Each prompt restarted the guessed 5 minutes (`UserPromptSubmit` wrote the timestamp).

**Fix**: No default: an unknown TTL shows `--:--`. The `Stop` hook waits up to 1 s for the response. The timestamp is the start of the last request that read or wrote the cache, from the transcript, not the hook time. See **Cache Timer Architecture**.

### `/proc/pid/stat` parsing with spaces in comm

**Bug**: `awk '{print $4}'` on `/proc/pid/stat` assumes field 4 is the PPID. The comm field (field 2, in parentheses) can contain spaces — e.g. `123 (my app) S 456 ...` — shifting all subsequent fields and returning the wrong value. The pty-discovery walk either terminates early or follows the wrong PID.

**Fix**: `awk '{sub(/.*\) /, ""); print $2}'` — strips everything through the closing `)` of comm before indexing fields, making PPID extraction robust regardless of the process name.

### First turn's cost delta lost (baseline captured too late)

**Bug**: The cost baseline was only captured at the first turn boundary, so the first turn's real cost (`total - 0`) was discarded — the sparkline and `delta` only appeared from the second turn onward.

**Fix**: Capture the baseline eagerly at tracking start and drop the `-n "$spark_marker"` requirement from `spark_record`. See **Cost Sparkline Architecture → State File** for the eager-capture semantics (the `spark_init` seed routed through the sole persist writer, and the fresh-vs-resumed baseline reasoning).

### extglob `*()` in a global substitution hangs the tick

**Bug**: `${s//\\033\[*([0-9;])[A-Za-z]/}` (strip ANSI with extglob) is super-linear: ~0.6 s on a 600-char line. The bars put one escape per cell, so a default line stalled every tick and live statusline processes piled up.

**Fix**: `_vis_width` — a loop of plain `%%` / `#` expansions plus one `${r%%[!0-9;]*}` per escape. Never use `*(...)`/`+(...)` inside `${var//...}` on the hot path.

### Lock mtime on macOS

**Bug**: `stat -c %Y` is GNU-only. On macOS it fails, `_lock_mtime` became 0, the lock looked ancient, and a failing refresh would retry every tick.

**Fix**: `stat -c %Y || stat -f %m`; a non-numeric mtime makes `_spawn_refresh` skip (keep waiting), never spawn.

### Hook scripts must use `#!/bin/bash`

Hooks are always invoked as `bash "script.sh"` from hooks.json. Using `#!/bin/sh` is misleading and forces unnecessary POSIX workarounds (e.g. `${VAR%${VAR#????????}}` instead of `${VAR:0:8}`). All hook scripts should use `#!/bin/bash` and bash substring syntax consistently.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo — one `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
