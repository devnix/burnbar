#!/bin/sh
# Burnbar SessionStart hook — auto-configures the statusline if not already set.

SETTINGS_FILE="$HOME/.claude/settings.json"
STATUSLINE_CMD="bash \"${CLAUDE_PLUGIN_ROOT}/statusline.sh\""

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo '{"message": "burnbar: jq is required but not installed. Install it with your package manager (apt install jq, brew install jq)."}'
  exit 0
fi

# Ensure settings file exists
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "{}" > "$SETTINGS_FILE"
fi

# Check if statusLine is already configured
current_statusline=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null)

if [ -n "$current_statusline" ]; then
  # Already configured — check if it points to burnbar
  case "$current_statusline" in
    *burnbar*|*"$CLAUDE_PLUGIN_ROOT"*)
      # Already using burnbar, nothing to do
      exit 0
      ;;
    *)
      # User has a different statusline configured — don't overwrite
      exit 0
      ;;
  esac
fi

# No statusline configured — set it up
tmp=$(mktemp)
jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"command": $cmd}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"

echo '{"message": "burnbar: Statusline configured. Restart Claude Code to see it in action."}'
