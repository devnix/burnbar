#!/bin/sh
# Burnbar SessionStart hook — auto-configures the statusline if not already set.
# Copies the script to a stable path so plugin version updates don't break it.

SETTINGS_FILE="$HOME/.claude/settings.json"
STABLE_SCRIPT="$HOME/.claude/burnbar-statusline.sh"
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
      # User has a different statusline configured — don't overwrite
      exit 0
      ;;
  esac
fi

# No statusline configured — set it up
tmp=$(mktemp)
jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"type": "command", "command": $cmd}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"

echo '{"message": "burnbar: Statusline configured. Restart Claude Code to see it in action."}'
