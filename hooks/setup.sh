#!/bin/bash
# Burnbar SessionStart hook — auto-configures the statusline only if none is set.
# Copies the script to a stable path so plugin version updates don't break it.

SETTINGS_FILE="$HOME/.claude/settings.json"
STABLE_SCRIPT="$HOME/.claude/burnbar-statusline.sh"
STATUSLINE_CMD="bash \"${STABLE_SCRIPT}\""

emit() {
  user_msg="$1"
  claude_ctx="$2"
  jq -n --arg sys "$user_msg" --arg ctx "$claude_ctx" \
    '{systemMessage: $sys, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo '{"systemMessage":"Burnbar: jq is required but not installed (apt install jq / brew install jq).","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Burnbar: jq is required but not installed. Tell the user to install it with their package manager (apt install jq, brew install jq)."}}'
  exit 0
fi

# Always recreate the symlink (keeps it pointing to the current plugin version)
ln -sf "${CLAUDE_PLUGIN_ROOT}/statusline.sh" "$STABLE_SCRIPT"

# Clear stale cache files for this session and old orphans
_sid="${CLAUDE_CODE_SESSION_ID:0:8}"
[ -n "$_sid" ] && rm -f "$HOME/.claude/.cache-ts-$_sid" "$HOME/.claude/.cache-notif-$_sid"
find "$HOME/.claude" -maxdepth 1 \( -name '.cache-ts-*' -o -name '.cache-meta-*' -o -name '.cache-notif-*' \) -mtime +1 -delete 2>/dev/null

# Ensure settings file exists
if [ ! -f "$SETTINGS_FILE" ]; then
  echo "{}" > "$SETTINGS_FILE"
fi

# Check if statusLine is already configured
current_statusline=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null)

if [ -n "$current_statusline" ]; then
  case "$current_statusline" in
    *burnbar*)
      current_refresh=$(jq -r '.statusLine.refreshInterval // empty' "$SETTINGS_FILE" 2>/dev/null)
      if [ -z "$current_refresh" ]; then
        tmp=$(mktemp)
        jq '.statusLine.refreshInterval = 1' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
        emit \
          "Burnbar: added refreshInterval for real-time cache timer. Restart Claude Code to activate." \
          "Burnbar added refreshInterval=1 to statusLine config for real-time cache countdown. Tell the user to restart Claude Code."
      fi
      exit 0
      ;;
    *)
      emit \
        "Burnbar: a different statusline is already configured. Run /burnbar to switch to Burnbar (your current config will be backed up)." \
        "Burnbar plugin is installed but a different statusline is already configured. Briefly tell the user they can run /burnbar to back up their current statusline and switch to Burnbar."
      exit 0
      ;;
  esac
fi

# No statusline configured — set it up
tmp=$(mktemp)
jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"type": "command", "command": $cmd, "refreshInterval": 1}' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"

emit \
  "Burnbar: statusline configured. Restart Claude Code to see it in action." \
  "Burnbar statusline has just been configured in ~/.claude/settings.json. Tell the user to restart Claude Code to see it in action."
