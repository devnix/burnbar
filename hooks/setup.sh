#!/bin/sh
# Burnbar SessionStart hook — auto-configures the statusline.
# Copies the script to a stable path so plugin version updates don't break it.
# Backs up any pre-existing statusline config before overwriting.

SETTINGS_FILE="$HOME/.claude/settings.json"
STABLE_SCRIPT="$HOME/.claude/burnbar-statusline.sh"
BACKUP_FILE="$HOME/.claude/burnbar-previous-statusline.json"
STATUSLINE_CMD="bash \"${STABLE_SCRIPT}\""

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo '{"message": "burnbar: jq is required but not installed. Install it with your package manager (apt install jq, brew install jq)."}'
  exit 0
fi

# Always copy the script to the stable path (keeps it up to date across plugin upgrades)
cp "${CLAUDE_PLUGIN_ROOT}/statusline.sh" "$STABLE_SCRIPT"
chmod +x "$STABLE_SCRIPT"

# Ensure settings file exists
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "{}" > "$SETTINGS_FILE"
fi

# Check if statusLine is already configured
current_statusline=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null)

if [ -n "$current_statusline" ]; then
  case "$current_statusline" in
    *burnbar*)
      # Already using burnbar — script was updated above, nothing else to do
      exit 0
      ;;
    *)
      # Different statusline — back up before overwriting
      jq '.statusLine' "$SETTINGS_FILE" > "$BACKUP_FILE"
      ;;
  esac
fi

# Configure burnbar statusline
tmp=$(mktemp)
jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"type": "command", "command": $cmd}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"

if [ -f "$BACKUP_FILE" ] && [ "$current_statusline" != "" ]; then
  echo "{\"message\": \"burnbar: Statusline configured. Previous config backed up to ~/.claude/burnbar-previous-statusline.json — to restore it, run: jq -s '.[0] * {statusLine: .[1]}' ~/.claude/settings.json ~/.claude/burnbar-previous-statusline.json\"}"
else
  echo '{"message": "burnbar: Statusline configured. Restart Claude Code to see it in action."}'
fi
