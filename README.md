# Burnbar 🔥

Rich statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — watch your tokens burn.

```
devnix@host:~/project
Claude 4 Opus  ██████████████░░░░░░░░░░░░░░░░  47%  ctx:94.2k  next:$0.42  total:$3.18
```

## Features

- **Context window progress bar** with color gradient (green → yellow → red)
- **Partial block characters** (▏▎▍▌▋▊▉) for smooth, sub-cell precision
- **Token count** showing current context size, color-matched to usage level
- **Cost tracking** — per-message input cost estimate and cumulative session total
- **Model-aware pricing** — auto-detects Opus/Sonnet/Haiku and applies correct rates
- **user@host:cwd** header line for quick orientation
- **Zero configuration** — installs and configures itself automatically

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

The statusline script is copied to `~/.claude/burnbar-statusline.sh` so it survives plugin version updates. On each session start, the script is refreshed from the latest plugin version.

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
       "command": "bash ~/.claude/statusline.sh"
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
| `/burnbar configure` | Interactively choose which modules to show |

## Configuration

Burnbar works out of the box with sensible defaults. All configuration is via environment variables — set them in your shell profile or inline in the statusline command.

### `BURNBAR_MODULES`

Comma-separated list of modules to display. Default: all modules enabled.

| Module | What it shows |
|--------|---------------|
| `header` | `user@host:cwd` line |
| `model` | Model name (e.g., "Claude 4 Opus") |
| `bar` | Context window progress bar with color gradient |
| `pct` | Usage percentage (e.g., "47%") |
| `ctx` | Current context tokens (e.g., "ctx:94.2k") |
| `next` | Estimated cost of the next message |
| `total` | Cumulative session cost |

Examples:

```bash
# Hide costs (useful when screen sharing)
export BURNBAR_MODULES="header,model,bar,pct,ctx"

# Minimal — just the bar and percentage
export BURNBAR_MODULES="bar,pct"

# Everything except the header line
export BURNBAR_MODULES="model,bar,pct,ctx,next,total"
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
    "command": "BURNBAR_MODULES='header,model,bar,pct,ctx' bash /path/to/statusline.sh"
  }
}
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
