#!/bin/bash
# Burnbar cache-touch hook — records the current timestamp per session.
# $1 is the hook event name (UserPromptSubmit, PostToolUse or Stop), passed
# by hooks.json. Uses CLAUDE_CODE_SESSION_ID env var (no jq needed).
# Config dir — respects secondary Claude profiles (CLAUDE_CONFIG_DIR)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -n "$CLAUDE_CODE_SESSION_ID" ] || exit 0
key="${CLAUDE_CODE_SESSION_ID:0:8}"
# printf %(...)T needs bash >= 4.2; macOS ships bash 3.2.
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
  printf -v now '%(%s)T' -1
else
  now=$(date +%s)
fi
# After an API call (PostToolUse, Stop), read the transcript tail, off the
# statusline hot path. No transcript or no match → keep the previous values.
#   Cache TTL (5m or 1h): Claude Code picks it per user (plan, settings, env),
#   and the statusline JSON carries no TTL breakdown. Read it from the last
#   main-thread cache write: the TTL can drop from 1h to 5m mid-turn (overage).
#   Model of the last call ("epoch|model"): the baseline of the model alert. A
#   switch during a turn changes the statusline model, not the model of the
#   call. Written before the timestamp, with the same epoch: the statusline
#   uses it only when the epochs match.
case "$1" in
  PostToolUse|Stop)
    # Read only the head: transcript_path is a base field near the start, and
    # tool_response can be MBs (bash reads a pipe byte by byte: ~0.35 s/MB).
    IFS= read -r -d '' -n 8192 _in
    if [[ "$_in" =~ \"transcript_path\":\ *\"([^\"]*)\" ]] && [ -f "${BASH_REMATCH[1]}" ]; then
      _tl=$(tail -c 262144 "${BASH_REMATCH[1]}" | grep -F '"isSidechain":false')
      _w=$(grep -o '"ephemeral_1h_input_tokens":[0-9]*,"ephemeral_5m_input_tokens":[0-9]*' <<< "$_tl" | tail -n 1)
      _h="${_w#*_1h_input_tokens\":}"; _h="${_h%%,*}"
      _m="${_w##*:}"
      if [ "${_h:-0}" -gt 0 ] 2>/dev/null; then
        printf '3600\n' > "$CONFIG_DIR/.cache-ttl-$key"
      elif [ "${_m:-0}" -gt 0 ] 2>/dev/null; then
        printf '300\n' > "$CONFIG_DIR/.cache-ttl-$key"
      fi
      # message.model is the first "model" key of the line: tool inputs come
      # later, and quotes inside strings are escaped.
      _a=$(grep -F '"type":"assistant"' <<< "$_tl" | tail -n 1)
      [[ "$_a" =~ \"model\":\"([^\"]*claude-[^\"]*)\" ]] &&
        printf '%s|%s\n' "$now" "${BASH_REMATCH[1]}" > "$CONFIG_DIR/.cache-model-$key"
    fi
    ;;
  # A prompt goes to the current model: clear the baseline of the last call
  # (no rm fork; same second as a Stop → the epochs match, the model is empty).
  UserPromptSubmit) printf '%s|\n' "$now" > "$CONFIG_DIR/.cache-model-$key" ;;
esac
printf '%s\n' "$now" > "$CONFIG_DIR/.cache-ts-$key"
# Turn boundary marker (Stop = Claude finished responding) — the statusline
# snapshots the cumulative cost when it changes. The $RANDOM suffix keeps
# markers distinct even for turns ending within the same second (the marker
# is an opaque string to the statusline).
[ "$1" = "Stop" ] && printf '%s\n' "$now-$RANDOM" > "$CONFIG_DIR/.turn-ts-$key"
exit 0
