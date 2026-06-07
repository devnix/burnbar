# Burnbar Development Notes

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

### Multi-Session Behavior

Claude Code runs the statusline command **for all active sessions**, not just the current one. The `model.id` in the JSON input alternates between sessions (e.g., sonnet/opus/haiku). Use `session_id` to isolate per-session state — never compare `model.id` across statusline evaluations without session isolation.

### `refreshInterval`

`statusLine.refreshInterval` controls how often (in seconds, 1–60) the statusline command runs. Set to `1` for real-time updates (required for the cache timer countdown).

## Cache Timer Architecture

### Timestamp Files (`~/.claude/.cache-ts-<session_prefix>`)

- Written by hooks (`UserPromptSubmit`, `PostToolUse`) using `date +%s`
- Key = first 8 chars of `session_id` (per-session isolation)
- Hooks use `$CLAUDE_CODE_SESSION_ID` env var (no jq needed)
- Statusline reads the same key via `${session_id:0:8}` from its JSON input
- Cleared on `SessionStart` to avoid stale data from previous sessions.

### Metadata Files (`~/.claude/.cache-meta-<session_prefix>`)

- Key = first 8 chars of `session_id` (per-session isolation)
- Format: `timestamp|model_family|effort_level` (pipe-delimited)
- **Baseline semantics**: model and effort are recorded when the file is created and reset on each new API call (`meta_ts != last`). Between API calls, the baseline is immutable — the alert persists while the current model/effort differs
- Baseline resets when the user sends a message or Claude uses a tool (hook fires → new timestamp), confirming the user is working with the current model
- Stale files (>1 day) cleaned on `SessionStart` via `find -mtime +1 -delete`

### Model Family Normalization

`model.id` changes subtly when effort level changes (e.g., different internal variant). To avoid false "model changed" alerts when only effort changed, compare by **family** (`opus`/`sonnet`/`haiku`) extracted via case pattern matching, not the full `model.id` string.

Alert priority: model first (if family changed), effort second (only if model family stayed the same).

### Notification Files (`~/.claude/.cache-notif-<session_prefix>`)

- Key = first 8 chars of `session_id` (same as timestamp files)
- Stores the cache timestamp (`$last`) for which the notification was already sent
- Prevents repeated notifications: only fires once per cache period when `remaining` crosses 50% of `CACHE_TTL`
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

## Performance

The script runs every 1 second. Minimize subprocess forks.

### Patterns That Work

- **Single jq call** with `@sh` + `eval` to extract all fields at once. Use `// ""` or `// 0` before `@sh` to guard against null producing literal `null`. Guard with `jq_out=$(...) && eval "$jq_out"` so jq failures don't eval garbage.
- **Single awk call** for all floating-point computation (bar geometry, cost formatting, token counts). Pass all inputs via `-v` flags.
- **`LC_NUMERIC=C`** before awk to prevent locale-dependent decimal separators.
- **`%.4f`** (not `%s`) for monetary values in awk — `%s` uses OFMT (%.6g) which produces scientific notation for large values and drops trailing zeros.
- **Inline shell arithmetic** for color thresholds instead of calling functions that fork awk per cell. Formula: `$((2*i+1)) -lt $BAR_WIDTH` for 50%, `$((10*i+5)) -lt $((BAR_WIDTH*8))` for 80%.
- **`${var:0:8}`** instead of `printf | cut` (bashism, zero forks).
- **`read -r var < file`** instead of `var=$(cat file)` (no fork).
- **`printf -v var`** instead of `var=$(printf ...)` (bash builtin, no fork).
- **`printf '%(%s)T' -1`** instead of `date +%s` (bash builtin, zero forks — saves 2 forks/tick on the hot path).
- **`$USER`** / **`${HOSTNAME%%.*}`** instead of `whoami` / `hostname -s`.

### Patterns That Don't Work

- **Separate jq calls** per field — each is 2 forks (subshell + jq). 10 calls = 20 forks.
- **Shell functions that pipe to awk** (`cell_bg`, `cell_fg`) called in a loop — up to 90 forks for BAR_WIDTH=30.
- **`tostring` without `@sh`** for numeric jq fields in eval — vulnerable to injection if the field is ever string-typed.

### Benchmark Reference

| Version | Forks | Time/invocation |
|---------|-------|-----------------|
| Original (many jq/awk, cell_bg/cell_fg) | ~150 | ~289ms |
| Optimized (batched jq+awk, inline colors) | ~18 | ~19ms |
| + printf %(%s)T (no date +%s) | ~16 | ~17ms |

## Known Bugs and Fixes

### Model/effort baseline must be immutable

**Bug**: If the meta file rewrites model/effort on every alert detection, the baseline drifts. The alert only shows for 1 tick (detected → meta rewritten → next tick sees no mismatch). Also, switching A→B→A triggers two alerts, even though the user returned to the original.

**Fix**: Baseline model/effort reset only on new API calls (`meta_ts != last`), not on alert detection. Between API calls the baseline is immutable, so the alert persists while the model/effort differs. Sending a message confirms the new model and resets the baseline.

### Notification sentinel written before delivery

**Bug**: Writing the sentinel file before sending the OSC/BEL sequence means a silent delivery failure (pty gone, permission error, swallowed by `2>/dev/null`) permanently suppresses the notification for the entire cache period — the sentinel is already set so subsequent ticks skip delivery.

**Fix**: Set `_sent=1` inside each `case` arm only on successful `printf` (`&& _sent=1`), write the sentinel only if `_sent=1`. Include `none) _sent=1 ;;` as an explicit arm.

### `has_cache=1` with an invalid timestamp

**Bug**: If the ts_file exists but contains empty or corrupt content, `last` is forced to 0 but `has_cache` is still set to 1. This renders a phantom 00:00 bar and may write a meta entry with `last=0`, causing spurious model-change alerts on subsequent ticks.

**Fix**: Wrap the elapsed/remaining calculation in `if [ "$last" -gt 0 ]` — only activate `has_cache` when the timestamp is a valid positive integer.

### `/proc/pid/stat` parsing with spaces in comm

**Bug**: `awk '{print $4}'` on `/proc/pid/stat` assumes field 4 is the PPID. The comm field (field 2, in parentheses) can contain spaces — e.g. `123 (my app) S 456 ...` — shifting all subsequent fields and returning the wrong value. The pty-discovery walk either terminates early or follows the wrong PID.

**Fix**: `awk '{sub(/.*\) /, ""); print $2}'` — strips everything through the closing `)` of comm before indexing fields, making PPID extraction robust regardless of the process name.

### Hook scripts must use `#!/bin/bash`

Hooks are always invoked as `bash "script.sh"` from hooks.json. Using `#!/bin/sh` is misleading and forces unnecessary POSIX workarounds (e.g. `${VAR%${VAR#????????}}` instead of `${VAR:0:8}`). All hook scripts should use `#!/bin/bash` and bash substring syntax consistently.
