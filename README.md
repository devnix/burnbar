# Burnbar 🔥

Rich statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — watch your tokens burn.

![Burnbar demo](https://github.com/devnix/burnbar/releases/download/0.1.1/burnbar.gif)

## Features

- **Cache TTL countdown** ⭐ — progress bar (optional) + `MM:SS` timer tracking the prompt cache window (5 minutes or 1 hour, detected per session), next to the cost of a cache miss. When 5 minutes remain (2:30 on a 5-minute cache), Burnbar fires a notification using Claude Code's own notification settings (terminal bell, iTerm2, Ghostty, Kitty — whatever you have configured). When the cache expires, `00:00` flashes red. No more paying to re-warm a cache you didn't know had expired.
- **Context window progress bar** with color gradient (green → yellow → red)
- **Partial block characters** (▏▎▍▌▋▊▉) for smooth, sub-cell precision
- **Token count** showing current context size, color-matched to usage level
- **Cost tracking** — per-message input cost estimate and cumulative session total
- **Model-aware pricing** — auto-detects Opus/Sonnet/Haiku and applies correct rates
- **user@host:cwd** header line for quick orientation
- **Zero configuration** — auto-configures on install; backs up any existing statusline

## Install

In Claude Code, run:

```
/plugin marketplace add devnix/burnbar
/plugin install burnbar@burnbar
```

Then restart Claude Code. The statusline appears automatically.

## How it works

Burnbar installs a `SessionStart` hook that auto-configures your statusline in `~/.claude/settings.json` — but only if no statusline is already set. If you already have one, Burnbar won't touch it.

To switch to Burnbar when you already have a statusline, use the `/burnbar` skill — it backs up your current config and lets you restore it later.

The statusline script is symlinked to `~/.claude/burnbar-statusline.sh`. On each session start, the symlink is recreated pointing to the current plugin version — so updates take effect immediately if the plugin directory is edited in place, or on the next restart after a version upgrade.

Secondary Claude profiles are supported: if `CLAUDE_CONFIG_DIR` is set, Burnbar uses it instead of `~/.claude` for settings, the stable script, and all cache state files. Set it in the environment when launching Claude Code so hooks and the statusline inherit it. Paths in this README show the `~/.claude` default — substitute your config dir if you use a profile.

## Requirements

- [jq](https://jqlang.github.io/jq/) — JSON processor (most systems have it; `apt install jq` / `brew install jq`)
- A terminal with ANSI color support (virtually all modern terminals)
- bash 3.2 or later (compatible with the stock macOS `/bin/bash`; not yet tested on a Mac)
- `curl` — only for `{monthly}`/`{daily}`, which read the billed spend of your Claude account (on macOS, from the login Keychain)

## Manual install

If you prefer not to use the plugin system:

1. Copy `statusline.sh` somewhere permanent (e.g., `~/.claude/statusline.sh`)
2. Add to `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "command": "bash ~/.claude/statusline.sh",
       "refreshInterval": 1
     }
   }
   ```
3. Restart Claude Code

## Skill: `/burnbar`

The plugin includes a `/burnbar` skill for managing the statusline from within Claude Code:

| Command | What it does |
|---------|--------------|
| `/burnbar` | Activate Burnbar (backs up existing statusline first, asks confirmation) |
| `/burnbar restore` | Restore the previous statusline from backup |
| `/burnbar status` | Show current statusline config and backup info |
| `/burnbar configure` | Edit the format string (hide/add elements, change layout) |

## Configuration

Burnbar works out of the box with sensible defaults. All configuration is via environment variables — set them in your shell profile or inline in the statusline command.

### `BURNBAR_FORMAT`

Format string for the statusline. Use `{tag}` placeholders for dynamic values, `\n` for newlines, and `\033[...]m...\033[00m` for ANSI colors. Any other text is rendered as-is.

| Tag | What it shows |
|-----|---------------|
| `{user}` | Current username |
| `{host}` | Hostname (short) |
| `{cwd}` | Current working directory |
| `{model}` | Model name (e.g., "Claude Sonnet 4.6") |
| `{bar}` | Context window progress bar with color gradient |
| `{pct}` | Usage percentage (e.g., "47%") |
| `{ctx}` | Current context tokens (e.g., "ctx:94.2k") |
| `{miss}` | Cost of the next message on a cache miss (e.g., "miss:$1.2160"); red when the cache has expired. See [Pricing model](#pricing-model) |
| `{next}` | Former name of `{miss}` (an alias) |
| `{total}` | Cumulative session cost |
| `{spark}` | Per-turn cost sparkline (see [Cost sparkline](#cost-sparkline)) |
| `{delta}` | Cost of the current turn, live; between turns, of the last turn (e.g., "delta:$0.0312") |
| `{cache}` | Cache TTL progress bar + `MM:SS` countdown (`BURNBAR_CACHE_WIDTH=0`: countdown only) |
| `{monthly}` | Billed spend of the billing period (Enterprise usage, extra-usage credits) from the claude.ai plan-usage endpoint, with the plan's limit as bar + `%`. `BURNBAR_MONTHLY_BUDGET` only applies when the plan has no limit. A `~` before the amount (`mo:~$98.33`) marks a reading older than 15 minutes: the endpoint failed (for example, rate limit) and the retries back off from 5 minutes up to 1 hour |
| `{daily}` | Today's billed spend, derived from `{monthly}` readings; bar + `%` when `BURNBAR_DAILY_BUDGET` is set; `~` as in `{monthly}` |
| `{5h}` | 5-hour plan-usage meter (bar + `%` + reset clock `↺HH:MM`); Pro/Max only |
| `{1w}` | 7-day plan-usage meter (bar + `%` + countdown + reset clock); Pro/Max only |
| `{sep}` | Responsive group separator — renders ` │ ` when the line fits, else a newline |
| `{wrap}` | Soft break — renders `BURNBAR_WRAP_SEP` (default two spaces) when the line fits, else a newline |

Static text can be wrapped in an **optional group** `[[ ... ]]`: the group (label
included) is shown only when at least one `{tag}` inside it is non-empty, and
disappears otherwise. The default format uses this so the `5h:`/`1w:`/`cache:`
labels vanish together with their meters when no data is available (e.g. `{5h}`
and `{1w}` are empty unless you are on a Pro/Max plan). Groups are flat and may not
contain `{sep}`/`{wrap}`.

Default (when `BURNBAR_FORMAT` is not set):

```bash
'\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}{wrap}{ctx} {bar} {pct}{sep}{total}{sep}[[cache: {cache}]] {miss}{sep}{delta} {spark}{sep}[[5h: {5h}]]{sep}[[1w: {1w}]]{sep}{monthly}{sep}{daily}'
```

Examples:

```bash
# Hide costs (useful when screen sharing)
export BURNBAR_FORMAT='\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}  {bar}  {pct}  {ctx}'

# Minimal — just the bar and percentage
export BURNBAR_FORMAT='{bar}  {pct}'

# Custom separator and emoji
export BURNBAR_FORMAT='{model} ·· {bar} {pct} 🔥 {ctx}  {miss}'

# Single line, no header
export BURNBAR_FORMAT='{model}  {bar}  {pct}  {ctx}  {total}  {cache} {miss}'
```

### `BURNBAR_BAR_WIDTH`

Progress bar width in terminal cells. Default: `20`.

```bash
export BURNBAR_BAR_WIDTH=20
```

### Setting env vars via Claude Code settings

You can set variables inline in your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "command": "BURNBAR_FORMAT='\\033[01;32m{user}@{host}\\033[00m:\\033[01;34m{cwd}\\033[00m\\n{model}  {bar}  {pct}  {ctx}' bash /path/to/statusline.sh"
  }
}
```

## Cache timer

The prompt cache has a TTL of 5 minutes or 1 hour — after expiration, your next message reprocesses the entire conversation (higher latency, higher cost; `{miss}` shows how much). The `{cache}` tag shows a progress bar that drains over the TTL with a `MM:SS` countdown, so you can decide whether to keep going or start fresh. To save space, hide the bar with `BURNBAR_CACHE_WIDTH=0`: the countdown keeps its colors and its flash on expiry.

Claude Code picks the TTL per user (subscription, settings, `ENABLE_PROMPT_CACHING_1H`). Burnbar reads it from the session transcript after each API call (the `PostToolUse` and `Stop` hooks): the last cache write tells 5m or 1h. Until the first cache write, the timer assumes 5 minutes. To force a value, set `BURNBAR_CACHE_TTL` (seconds).

| Color | Remaining | Meaning |
|-------|-----------|---------|
| Grey | `--:--` | No API call yet (session just started) |
| Green | > 40% of the TTL (> 2 min on a 5m cache) | Cache is warm |
| Yellow | 20–40% (1–2 min) | Approaching expiration |
| Red | < 20% (< 1 min) | Near expiration |
| Flashing red | `00:00` | Expired: the next message pays `{miss}`. Needs `refreshInterval: 1` |

The timer resets on every API call — when you submit a message (`UserPromptSubmit`) or Claude uses a tool (`PostToolUse`). Before your first interaction, the bar renders in a neutral grey state with `--:--`.

### Model & effort change tracking

When the cache is created, Burnbar records the current model and effort level (per-session, using `session_id`). If you switch models or effort without sending a new message, a **`⚠ model`** or **`⚠ effort`** alert appears — the existing cache may not apply. The alert clears on your next API call.

`⚠ effort` shows only on the models where an effort change rewrites the cache: Opus 4.5–4.8, Opus 5, Sonnet 4.6, Sonnet 5, Fable 5, Mythos 5 and Mythos 5.1. On Fable 5.1, Opus 5.5, Sonnet 5.5 and Haiku 5.5, Claude Code sends the change as a per-turn message and the cache stays. Exception: with `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`, on Vertex, or on Bedrock without Mantle, Claude Code cannot send that message, so every model alerts.

### Per-workspace isolation

Each workspace gets its own cache timer. On session start, the cache is cleared automatically so stale data from previous sessions never causes false alerts. Timestamp files live at `~/.claude/.cache-ts-<hash>` (or `$CLAUDE_CONFIG_DIR/.cache-ts-<hash>` for secondary profiles). Clean up with `rm ~/.claude/.cache-ts-*`.

### `BURNBAR_NOTIFY_LEAD`

Seconds before cache expiry when the notification fires. Default: `300`. Capped at half the TTL, so a 5-minute cache notifies at 2:30.

```bash
export BURNBAR_NOTIFY_LEAD=600
```

### `BURNBAR_CACHE_WIDTH`

Cache progress bar width in terminal cells. Default: `8`. Set `0` to hide the bar and keep only the colored `MM:SS` countdown.

```bash
export BURNBAR_CACHE_WIDTH=15
export BURNBAR_CACHE_WIDTH=0   # countdown only, saves space
```

## Cost sparkline

The `{spark}` tag draws a compact bar chart of how much each turn cost, so spending spikes stand out at a glance:

```
total:$3.42  ⣀⣀⣀⣸⣀⣠⣀⣀
```

Each turn's cost (the delta of `cost.total_cost_usd` between responses) is scaled against the most expensive turn in the visible window. In the default braille/octant modes, each terminal cell packs **two turns** side by side — the default 8 cells cover the last 16 turns.

The sparkline always renders at its full configured width — unused cells show the same grey background as the unfilled bar sections, so the layout stays stable as turns accumulate.

The current turn is live: while Claude works, its cost so far is drawn as the last column and grows with each API call. When the turn ends, the recorded cost replaces it in the same slot. If the live turn becomes the most expensive one in the window, the older bars shrink to keep the scale.

The `{delta}` tag shows the cost of the current turn while it runs, and the cost of the most recent turn between turns.

### `BURNBAR_SPARK`

Rendering mode. Default: `auto`.

| Mode | Cell grid | Turns/cell | Notes |
|------|-----------|------------|-------|
| `auto` | — | — | `octant` on Ghostty/Kitty, `braille` elsewhere |
| `braille` | 2×4 dots | 2 | Universal font support |
| `octant` | 2×4 solid | 2 | Unicode 16 block octants — best looks, needs terminal support |
| `blocks` | 1×8 | 1 | Classic `▁▂▃▄▅▆▇█` sparkline |
| `none` | — | — | Disable (skips cost-history tracking; the turn-marker hook still runs) |

```bash
export BURNBAR_SPARK=blocks
```

### `BURNBAR_SPARK_WIDTH`

Sparkline width in terminal cells. Default: `8` (= 16 turns in braille/octant, 8 in blocks).

```bash
export BURNBAR_SPARK_WIDTH=12
```

## Pricing model

The `total` cost uses Claude Code's authoritative `cost.total_cost_usd` field.

The `miss` cost is what the next message costs on a cache miss: the whole current context is written to the cache again.

```
miss = context tokens × base input price × (1.25 on a 5m cache | 2 on a 1h cache)
```

It is a lower bound for that message: it excludes the output, the thinking, and the tool calls of the turn. While the cache is warm, the next message pays much less (cache reads), so `{delta}` is the better guide for the cost of a turn. `{miss}` tells you what waiting until the timer runs out costs.

Base input prices (per 1M tokens, Anthropic API, 2026-10):

| Model | Input |
|-------|-------|
| Fable 5 / 5.1, Mythos | $10.00 |
| Opus 5.5 | $4.00 |
| Opus 5, Opus 4.5–4.8 | $5.00 |
| Opus 4 / 4.1, Opus 3 | $15.00 |
| Sonnet 5 / 5.5 | $2.00 |
| Sonnet 3.5–4.6 | $3.00 |
| Haiku 5.5 | $0.10 (≤ 100K context), $0.50 above |
| Haiku 4.5 | $1.00 |
| Haiku 3.5 | $0.80 |
| Haiku 3 | $0.25 |

An unlisted version of a known family uses the newest price of that family. Not included: fast mode, Batch and Bedrock / Vertex prices.

### `BURNBAR_FRESH_PRICES`

By default, Burnbar refreshes the prices of `{miss}` once a day from [models.dev](https://models.dev) (Anthropic models only). A new model then gets its price before a Burnbar update. Set `0` to use only the table above, with no request to models.dev.

```bash
export BURNBAR_FRESH_PRICES=0
```

- The download (~0.5 MB compressed) runs in the background, only when the format contains `{miss}`. The statusline never waits for it.
- A model that is not in the download, a download older than 7 days, or a failed download uses the table above. After a failure, the next attempt waits 6 hours.
- The cache is `~/.cache/burnbar-prices`.

## Uninstall

In Claude Code, run:

```
/plugin uninstall burnbar@burnbar
```

To restore your previous statusline, use `/burnbar restore` or manually delete the `"statusLine"` key from `~/.claude/settings.json`.

## License

[Fistro Public License v1.0 "Diodená"](https://github.com/devnix/fistro-public-license) — haz lo que te salga del fistro duodenarl.
