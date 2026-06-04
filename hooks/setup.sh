#!/bin/sh
# Burnbar SessionStart hook — auto-configures the statusline only if none is set.
# Copies the script to a stable path so plugin version updates don't break it.

SETTINGS_FILE="$HOME/.claude/settings.json"
STABLE_SCRIPT="$HOME/.claude/burnbar-statusline.sh"
STATUSLINE_CMD="bash \"${STABLE_SCRIPT}\""

emit() {
  jq -n --arg ctx "$1" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"burnbar: jq is required but not installed. Tell the user to install it with their package manager (apt install jq, brew install jq)."}}'
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
      exit 0
      ;;
    *)
      emit "burnbar plugin is installed but a different statusline is already configured. Briefly tell the user they can run /burnbar to back up their current statusline and switch to burnbar."
      exit 0
      ;;
  esac
fi

# No statusline configured — set it up
tmp=$(mktemp)
jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"type": "command", "command": $cmd}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"

emit "burnbar statusline has just been configured in ~/.claude/settings.json. Tell the user to restart Claude Code to see it in action."
