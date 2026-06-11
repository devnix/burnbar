#!/bin/bash
# Burnbar cache-touch hook — records the current timestamp per session.
# $1 is the hook event name (UserPromptSubmit, PostToolUse or Stop), passed
# by hooks.json. Uses CLAUDE_CODE_SESSION_ID env var (no jq needed).
# Config dir — respects secondary Claude profiles (CLAUDE_CONFIG_DIR)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -n "$CLAUDE_CODE_SESSION_ID" ] || exit 0
key="${CLAUDE_CODE_SESSION_ID:0:8}"
printf -v now '%(%s)T' -1
printf '%s\n' "$now" > "$CONFIG_DIR/.cache-ts-$key"
# Turn boundary marker (Stop = Claude finished responding) — the statusline
# snapshots the cumulative cost when it changes. The $RANDOM suffix keeps
# markers distinct even for turns ending within the same second (the marker
# is an opaque string to the statusline).
[ "$1" = "Stop" ] && printf '%s\n' "$now-$RANDOM" > "$CONFIG_DIR/.turn-ts-$key"
exit 0
