---
name: burnbar
description: Configure, restore, or check the status of the Burnbar statusline. Use when the user invokes `/burnbar`, asks to configure the statusline, restore a previous statusline, or check Burnbar settings.
argument-hint: "[restore|status|configure]"
---

# Burnbar — Statusline Manager

You manage the Burnbar statusline configuration for Claude Code.

## Paths

- **Settings**: `~/.claude/settings.json` (the `statusLine` key)
- **Script**: `~/.claude/burnbar-statusline.sh` (stable copy of the statusline script)
- **Backup**: `~/.claude/burnbar-previous-statusline.json` (previous statusline config, if any)

## Commands

Determine the user's intent from their message:

### Setup / Activate

The user wants to switch to Burnbar (e.g., "configure Burnbar", "activate Burnbar", "use Burnbar", or just `/burnbar` with no other context).

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

The user wants to restore their previous statusline (e.g., "restore statusline", "undo Burnbar", `/burnbar restore`).

1. Check if `~/.claude/burnbar-previous-statusline.json` exists
2. If not, tell the user there's no backup to restore
3. If it exists, read it, show the user what will be restored, and ask for confirmation
4. After confirmation, read `~/.claude/settings.json`, replace the `statusLine` key with the backup content, and write it back
5. Tell the user to restart Claude Code

### Status

The user wants to know the current state (e.g., "Burnbar status", "is Burnbar active?").

1. Read `~/.claude/settings.json` and show the current `statusLine` config
2. Check if `~/.claude/burnbar-previous-statusline.json` exists and mention it if so
3. Check if `~/.claude/burnbar-statusline.sh` exists

### Configure format

The user wants to change the statusline layout (e.g., "hide costs", "show only bar", "use a custom format", "configure Burnbar format").

Available tags: `{user}`, `{host}`, `{cwd}`, `{model}`, `{bar}`, `{pct}`, `{ctx}`, `{next}`, `{total}`

Use `\n` for newlines and `\033[...]m...\033[00m` for ANSI colors in the format string.

1. Ask the user which layout they want, or help them build a format string
2. Read `~/.claude/settings.json`
3. Update `statusLine.command` to prepend `BURNBAR_FORMAT='...'` before the bash command
4. If they want to change bar width, also prepend `BURNBAR_BAR_WIDTH=N`
5. Tell the user to restart Claude Code

**CRITICAL: the format string must be single-quoted in the command to prevent shell expansion.**

Example commands:

```
# Default (all elements, colored header)
BURNBAR_FORMAT='\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}  {bar}  {pct}  {ctx}  {next}  {total}' bash "/home/user/.claude/burnbar-statusline.sh"

# Hide costs (screen sharing)
BURNBAR_FORMAT='\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}  {bar}  {pct}  {ctx}' bash "/home/user/.claude/burnbar-statusline.sh"

# Minimal
BURNBAR_FORMAT='{bar}  {pct}' bash "/home/user/.claude/burnbar-statusline.sh"

# Costs only
BURNBAR_FORMAT='{next}  {total}' bash "/home/user/.claude/burnbar-statusline.sh"
```

## Important

- Always ask for confirmation before modifying `~/.claude/settings.json`
- Always use the Read tool before editing any file
- Use `$HOME` expanded (the actual path like `/home/username/`), not literal `~` in file paths for tool calls
- When writing JSON, preserve all other keys in settings.json — only modify `statusLine`
