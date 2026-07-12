# Burnbar 🔥

Rich statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — watch your tokens burn.

![Burnbar demo](https://github.com/devnix/burnbar/releases/download/0.1.1/burnbar.gif)

## Features

- **Cache TTL countdown** ⭐ — progress bar + `MM:SS` timer tracking the 5-minute prompt cache window. When half the time is gone, Burnbar fires a notification using Claude Code's own notification settings (terminal bell, iTerm2, Ghostty, Kitty — whatever you have configured). No more paying to re-warm a cache you didn't know had expired.
- **Context window progress bar** with color gradient (green → yellow → red)
- **Partial block characters** (▏▎▍▌▋▊▉) for smooth, sub-cell precision
- **Token count** showing current context size, color-matched to usage level
- **Cost tracking** — per-message input cost estimate and cumulative session total
- **Model-aware pricing** — auto-detects Fable/Opus/Sonnet/Haiku (including legacy price tiers) and applies correct rates
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
| `{next}` | Estimated cost of the next message |
| `{total}` | Cumulative session cost |
| `{spark}` | Per-turn cost sparkline (see [Cost sparkline](#cost-sparkline)) |
| `{delta}` | Last turn's cost delta (e.g., "delta:$0.0312") |
| `{cache}` | Cache TTL progress bar + `MM:SS` countdown |

Default (when `BURNBAR_FORMAT` is not set):

```bash
'\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}  {bar}  {pct}  {ctx}  {next}  {total}  {cache}  {spark}  {delta}'
```

Examples:

```bash
# Hide costs (useful when screen sharing)
export BURNBAR_FORMAT='\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}  {bar}  {pct}  {ctx}'

# Minimal — just the bar and percentage
export BURNBAR_FORMAT='{bar}  {pct}'

# Custom separator and emoji
export BURNBAR_FORMAT='{model} ·· {bar} {pct} 🔥 {ctx}  {next}'

# Single line, no header
export BURNBAR_FORMAT='{model}  {bar}  {pct}  {ctx}  {next}  {total}  {cache}'
```

### `BURNBAR_BAR_WIDTH`

Progress bar width in terminal cells. Default: `30`.

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

The prompt cache has a 5-minute TTL — after expiration, your next message reprocesses the entire conversation (higher latency, higher cost). The `{cache}` tag shows a progress bar that drains over 5 minutes with a `MM:SS` countdown, so you can decide whether to keep going or start fresh.

| Color | Remaining | Meaning |
|-------|-----------|---------|
| Grey | `--:--` | No API call yet (session just started) |
| Green | > 2 min | Cache is warm |
| Yellow | 1–2 min | Approaching expiration |
| Red | < 1 min | Near expiration / expired |

The timer resets on every API call — when you submit a message (`UserPromptSubmit`) or Claude uses a tool (`PostToolUse`). Before your first interaction, the bar renders in a neutral grey state with `--:--`.

### Model & effort change tracking

When the cache is created, Burnbar records the current model and effort level (per-session, using `session_id`). If you switch models or effort without sending a new message, a **`⚠ model`** or **`⚠ effort`** alert appears — the existing cache may not apply. The alert clears on your next API call.

### Per-workspace isolation

Each workspace gets its own cache timer. On session start, the cache is cleared automatically so stale data from previous sessions never causes false alerts. Timestamp files live at `~/.claude/.cache-ts-<hash>` (or `$CLAUDE_CONFIG_DIR/.cache-ts-<hash>` for secondary profiles). Clean up with `rm ~/.claude/.cache-ts-*`.

### `BURNBAR_CACHE_WIDTH`

Cache progress bar width in terminal cells. Default: `10`.

```bash
export BURNBAR_CACHE_WIDTH=15
```

## Cost sparkline

The `{spark}` tag draws a compact bar chart of how much each turn cost, so spending spikes stand out at a glance:

```
total:$3.42  ⣀⣀⣀⣸⣀⣠⣀⣀
```

Each turn's cost (the delta of `cost.total_cost_usd` between responses) is scaled against the most expensive turn in the visible window. In the default braille/octant modes, each terminal cell packs **two turns** side by side — the default 8 cells cover the last 16 turns.

The sparkline always renders at its full configured width — unused cells show the same grey background as the unfilled bar sections, so the layout stays stable as turns accumulate.

The first data point appears after Claude's second response (one full turn must complete to measure its cost). The `{delta}` tag shows the numeric value of the most recent turn's cost.

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

Cost estimates use the following rates (per 1M tokens):

| Model | Input | Cache Write | Cache Read |
|-------|-------|------------|------------|
| Opus | $15.00 | $18.75 | $1.50 |
| Sonnet | $3.00 | $3.75 | $0.30 |
| Haiku | $0.80 | $1.00 | $0.08 |

The `total` cost uses Claude Code's authoritative `cost.total_cost_usd` field. The `next` cost is an estimate of the current context input cost.

## Uninstall

In Claude Code, run:

```
/plugin uninstall burnbar@burnbar
```

To restore your previous statusline, use `/burnbar restore` or manually delete the `"statusLine"` key from `~/.claude/settings.json`.

## License

[Fistro Public License v1.0 "Diodená"](https://github.com/devnix/fistro-public-license) — haz lo que te salga del fistro duodenarl.
