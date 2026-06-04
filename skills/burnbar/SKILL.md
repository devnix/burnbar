---
name: burnbar
description: Configure, restore, or check the status of the burnbar statusline. Use when the user invokes `/burnbar`, asks to configure the statusline, restore a previous statusline, or check burnbar settings.
argument-hint: "[restore|status|configure]"
---

# Burnbar — Statusline Manager

You manage the burnbar statusline configuration for Claude Code.

## Paths

- **Settings**: `~/.claude/settings.json` (the `statusLine` key)
- **Script**: `~/.claude/burnbar-statusline.sh` (stable copy of the statusline script)
- **Backup**: `~/.claude/burnbar-previous-statusline.json` (previous statusline config, if any)

## Commands

Determine the user's intent from their message:

### Setup / Activate

The user wants to switch to burnbar (e.g., "configure burnbar", "activate burnbar", "use burnbar", or just `/burnbar` with no other context).

1. Read `~/.claude/settings.json`
2. Check if `statusLine.command` already contains "burnbar" → if so, tell the user it's already active and show current config
3. If a different statusline exists:
   - Back it up: read the current `statusLine` object and write it to `~/.claude/burnbar-previous-statusline.json`
   - Tell the user what you backed up and that they can restore it with `/burnbar restore`
   - Ask the user for confirmation before overwriting
4. After confirmation, set `statusLine` to:
   ```json
   {
     "type": "command",
     "command": "bash \"~/.claude/burnbar-statusline.sh\""
   }
   ```
   (Use the literal expanded path for `~`, not the tilde)
5. Tell the user to restart Claude Code for changes to take effect

### Restore

The user wants to restore their previous statusline (e.g., "restore statusline", "undo burnbar", `/burnbar restore`).

1. Check if `~/.claude/burnbar-previous-statusline.json` exists
2. If not, tell the user there's no backup to restore
3. If it exists, read it, show the user what will be restored, and ask for confirmation
4. After confirmation, read `~/.claude/settings.json`, replace the `statusLine` key with the backup content, and write it back
5. Tell the user to restart Claude Code

### Status

The user wants to know the current state (e.g., "burnbar status", "is burnbar active?").

1. Read `~/.claude/settings.json` and show the current `statusLine` config
2. Check if `~/.claude/burnbar-previous-statusline.json` exists and mention it if so
3. Check if `~/.claude/burnbar-statusline.sh` exists

### Configure modules

The user wants to change which modules are shown (e.g., "hide costs", "show only bar", "configure burnbar modules").

Available modules: `header`, `model`, `bar`, `pct`, `ctx`, `next`, `total`

1. Ask the user which modules they want
2. Read `~/.claude/settings.json`
3. Update `statusLine.command` to prepend `BURNBAR_MODULES='...'` before the bash command
4. If they want to change bar width, also prepend `BURNBAR_BAR_WIDTH=N`
5. Tell the user to restart Claude Code

**CRITICAL: `BURNBAR_MODULES` uses COMMAS as separator, NOT spaces.**

Example commands for common presets:
```
# All modules (default)
BURNBAR_MODULES='header,model,bar,pct,ctx,next,total' bash "/home/user/.claude/burnbar-statusline.sh"

# Hide costs (screen sharing)
BURNBAR_MODULES='header,model,bar,pct,ctx' bash "/home/user/.claude/burnbar-statusline.sh"

# Minimal
BURNBAR_MODULES='bar,pct' bash "/home/user/.claude/burnbar-statusline.sh"

# Costs only
BURNBAR_MODULES='next,total' bash "/home/user/.claude/burnbar-statusline.sh"
```

## Important

- Always ask for confirmation before modifying `~/.claude/settings.json`
- Always use the Read tool before editing any file
- Use `$HOME` expanded (the actual path like `/home/username/`), not literal `~` in file paths for tool calls
- When writing JSON, preserve all other keys in settings.json — only modify `statusLine`
