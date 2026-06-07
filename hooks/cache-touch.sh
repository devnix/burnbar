#!/bin/bash
# Burnbar cache-touch hook — records the current timestamp per session.
# Called by UserPromptSubmit and PostToolUse hooks.
# Uses CLAUDE_CODE_SESSION_ID env var (no jq needed).
[ -n "$CLAUDE_CODE_SESSION_ID" ] \
  && date +%s > "$HOME/.claude/.cache-ts-${CLAUDE_CODE_SESSION_ID:0:8}"
