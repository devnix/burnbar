#!/bin/bash
# Burnbar cache-touch hook — records the cache state of the session from the
# transcript, after each API call. $1 is the hook event name (PreToolUse,
# PostToolUse or Stop), passed by hooks.json. Uses CLAUDE_CODE_SESSION_ID env var.
# Config dir — respects secondary Claude profiles (CLAUDE_CONFIG_DIR)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -n "$CLAUDE_CODE_SESSION_ID" ] || exit 0
key="${CLAUDE_CODE_SESSION_ID:0:8}"
case "$1" in PreToolUse|PostToolUse|Stop) ;; *) exit 0 ;; esac

# Read only the head: the base fields are near the start, and tool_input can be
# MBs (bash reads a pipe byte by byte: ~0.35 s/MB).
IFS= read -r -d '' -n 8192 _in
# A subagent has its own cache: its events say nothing about the main thread.
# agent_id comes before hook_event_name, so tool_input cannot fake it.
case "${_in%%\"hook_event_name\"*}" in *'"agent_id"'*) exit 0 ;; esac

# Turn boundary marker (Stop = Claude finished responding) — the statusline
# snapshots the cumulative cost when it changes. The $RANDOM suffix keeps
# markers distinct even for turns ending within the same second (the marker
# is an opaque string to the statusline).
if [ "$1" = "Stop" ]; then
  # printf %(...)T needs bash >= 4.2; macOS ships bash 3.2.
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
    printf -v now '%(%s)T' -1
  else
    now=$(date +%s)
  fi
  printf '%s\n' "$now-$RANDOM" > "$CONFIG_DIR/.turn-ts-$key"
fi

[[ "$_in" =~ \"transcript_path\":\ *\"([^\"]*)\" ]] && [ -f "${BASH_REMATCH[1]}" ] || exit 0
_tr="${BASH_REMATCH[1]}"

# One pass over the main-thread entries of the transcript tail (subagents have
# their own cache). Prints "last|epoch|ttl|model":
#   last  — type of the last user/assistant entry: "assistant" once the
#           response of the last API call is in the transcript.
#   epoch — start of the last API call that read or wrote the cache: the
#           evidence that the cache lives. A read refreshes the lifetime too,
#           and the lifetime runs from the start of the request. Claude Code
#           logs each request ("api-request", no isSidechain) between the
#           parent entry of the first response block (the prompt or the tool
#           result) and the block. No request entry → the parent (early by the
#           prompt hooks, ~2 s); no parent in the tail → the block (late by
#           the first tokens).
#   ttl   — TTL of the last cache write: 3600 if it wrote 1h tokens, else 300.
#           A pure read carries no TTL.
#   model — model of that call: the baseline of the model alert.
# Empty fields = no evidence: nothing is written.
_jq='[inputs | fromjson? | select(type == "object")] as $all
| [range(0; $all | length) as $i | $all[$i] + {_i: $i}] as $x
| [$x[] | select(.isSidechain == false)] as $e
| ([$e[]| select(.type == "user" or .type == "assistant") | .type] | last // "") as $last
| [$e[] | select(.type == "assistant")] as $a
| ([$a[] | select(((.message.usage.cache_read_input_tokens // 0)
                 + (.message.usage.cache_creation_input_tokens // 0)) > 0)] | last) as $ev
| ([$a[] | .message.usage.cache_creation
         | select(. != null and ((.ephemeral_1h_input_tokens // 0) + (.ephemeral_5m_input_tokens // 0)) > 0)]
   | last) as $cw
| (if $ev == null then null else
     ([$a[] | select(.message.id != null and .message.id == $ev.message.id)] | first // $ev) as $f
     | ([$e[] | select(.uuid != null and .uuid == $f.parentUuid)] | last) as $p
     | ([$x[] | select(.type == "api-request" and ._i < $f._i and ._i > ($p._i // -1))] | last) as $r
     | ($r.timestamp // $p.timestamp // $f.timestamp)
   end) as $t
| [$last,
   (try ($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch ""),
   (if $cw == null then "" elif ($cw.ephemeral_1h_input_tokens // 0) > 0 then 3600 else 300 end),
   ($ev.message.model // "")]
| map(tostring) | join("|")'
_parse() {
  IFS='|' read -r _last _ep _ttl _model <<< "$(tail -c 262144 "$_tr" | jq -nrR "$_jq" 2>/dev/null)"
}
_parse
# PreToolUse and Stop fire before Claude Code writes the response to the
# transcript (measured: absent at +0 s, present at +0.2 s). Wait for it, up to
# 1 s; then use what is there. PreToolUse is async: the tool does not wait. In
# PostToolUse the response is already there: no wait.
_i=0
while [ "$_last" != "assistant" ] && [ "$_i" -lt 10 ]; do
  sleep 0.1
  _parse
  _i=$((_i + 1))
done

case "$_ttl" in 300|3600) printf '%s\n' "$_ttl" > "$CONFIG_DIR/.cache-ttl-$key" ;; esac
[ "${_ep:-0}" -gt 0 ] 2>/dev/null || exit 0
_old=0
[ -f "$CONFIG_DIR/.cache-ts-$key" ] && read -r _old < "$CONFIG_DIR/.cache-ts-$key"
[ "${_old:-0}" -gt 0 ] 2>/dev/null || _old=0
# Newer evidence only: the timer never moves back.
[ "$_ep" -gt "$_old" ] || exit 0
# The model file goes first, with the same epoch as the timestamp: the
# statusline uses it only when the epochs match.
case "$_model" in
  *claude-*) printf '%s|%s\n' "$_ep" "$_model" > "$CONFIG_DIR/.cache-model-$key" ;;
esac
printf '%s\n' "$_ep" > "$CONFIG_DIR/.cache-ts-$key"
exit 0
