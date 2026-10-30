#!/usr/bin/env bash
# Burnbar cache timer test.
#
# The cache-touch hook reads the cache state from the transcript after each
# API call (PreToolUse, Stop). The timer restarts only on evidence: a
# main-thread response that read or wrote the cache. The timestamp is the
# start of that request (its "api-request" entry); the TTL (5m or 1h) comes
# from the last cache write. No evidence yet → the statusline shows no
# countdown, no notification and no {miss}: it never guesses.
#
# Usage: tests/cache-ttl.sh
# Env:   TEST_BASH — bash binary under test (default: bash)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; HOM="$TMP/home"; mkdir -p "$CFG" "$HOM"
SID="ttltest-0000-0000"; KEY="${SID:0:8}"
TS="$CFG/.cache-ts-$KEY"; TTL="$CFG/.cache-ttl-$KEY"
TR="$TMP/transcript.jsonl"
fail=0

check() {  # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

hook() {  # $1 = event, $2 = tool_response (optional)
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"%s","tool_response":"%s"}' \
    "$SID" "$TR" "$1" "${2:-}" |
    env -i PATH="$PATH" HOME="$HOM" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" \
      "$TEST_BASH" "$REPO/hooks/cache-touch.sh" "$1"
}

# ── Transcript entries (epochs relative to E) ─────────────────────────────────
E=$(( $(date +%s) - 3000 ))
iso() {  # $1 = seconds after E → ISO 8601 UTC with milliseconds, as Claude Code writes it
  local t=$(( E + $1 ))
  date -u -d "@$t" +%Y-%m-%dT%H:%M:%S.123Z 2>/dev/null || date -u -r "$t" +%Y-%m-%dT%H:%M:%S.123Z
}
prompt() {  # $1 = uuid, $2 = epoch
  printf '{"isSidechain":false,"type":"user","uuid":"%s","timestamp":"%s","message":{"role":"user","content":"hi"}}\n' \
    "$1" "$(iso "$2")" >> "$TR"
}
request() {  # $1 = epoch (no isSidechain, as Claude Code writes it)
  printf '{"type":"api-request","timestamp":"%s","querySource":"repl_main_thread"}\n' "$(iso "$1")" >> "$TR"
}
# $1 = uuid, $2 = parent uuid, $3 = epoch, $4 = message id, $5 = read tokens,
# $6 = 5m write tokens, $7 = 1h write tokens, $8 = isSidechain (default false)
block() {
  printf '{"isSidechain":%s,"type":"assistant","uuid":"%s","parentUuid":"%s","timestamp":"%s","message":{"id":"%s","model":"claude-opus-5-5","usage":{"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d,"cache_creation":{"ephemeral_1h_input_tokens":%d,"ephemeral_5m_input_tokens":%d}}}}\n' \
    "${8:-false}" "$1" "$2" "$(iso "$3")" "$4" "$5" "$(( $6 + $7 ))" "$7" "$6" >> "$TR"
}

ttl() { local t=""; [ -f "$TTL" ] && read -r t < "$TTL"; echo "${t:-none}"; }
ts()  { local t=""; [ -f "$TS" ] && read -r t < "$TS"; [ -n "$t" ] && echo "E$(( t - E ))" || echo none; }

# ── Hook: evidence, anchor and TTL ────────────────────────────────────────────
: > "$TR"
hook PreToolUse;          check "no response yet → no TTL"              none "$(ttl)"
                           check "no response yet → no timestamp"        none "$(ts)"
prompt p1 0; request 2; block a1 p1 5 m1 0 0 1200
hook PreToolUse;          check "1h write → 3600"                       3600 "$(ttl)"
                           check "timestamp = start of the request"      E2   "$(ts)"
block a2 a1 9 m1 0 0 1200; hook PreToolUse
                           check "later block of the same call → same"   E2   "$(ts)"
hook UserPromptSubmit;     check "prompt is not evidence"                E2   "$(ts)"
prompt p2 20; block a3 p2 24 m2 0 800 0
hook PreToolUse;          check "5m write → 300"                        300  "$(ttl)"
                           check "no request entry → the prompt"         E20  "$(ts)"
prompt p3 30; request 31; block a4 p3 33 m3 5000 0 0
hook PreToolUse;          check "a read refreshes the timer"            E31  "$(ts)"
                           check "a read keeps the TTL"                  300  "$(ttl)"
prompt p4 40; request 41; block a5 p4 43 m4 0 0 0
hook PreToolUse;          check "no cache use → no restart"             E31  "$(ts)"
request 50; block s1 x 52 m5 0 0 900 true
hook PreToolUse;          check "subagent write → ignored (ts)"         E31  "$(ts)"
                           check "subagent write → ignored (TTL)"        300  "$(ttl)"
prompt p6 60; request 61; block a6 p6 63 m6 0 500 900
hook PreToolUse;          check "mixed write → 1h"                      3600 "$(ttl)"
                           check "mixed write → timestamp"               E61  "$(ts)"
echo "$(( E + 100 ))" > "$TS"; hook PreToolUse
                           check "older evidence → no move back"         E100 "$(ts)"
# A large tool_response: the hook reads only the head of its stdin.
big=$(head -c 1048576 /dev/zero | tr '\0' a)
prompt p7 200; request 202; block a7 p7 204 m7 0 600 0
hook PreToolUse "$big";   check "1 MB tool_response"                    E202 "$(ts)"
mv "$TR" "$TR.bak";        hook Stop
                           check "missing transcript keeps"              E202 "$(ts)"
mv "$TR.bak" "$TR"

# Stop fires before the last response is in the transcript: the hook waits.
prompt p8 300; request 302
hook Stop & stop_pid=$!
sleep 0.3; block a8 p8 305 m8 6000 0 0
wait "$stop_pid"
                           check "Stop waits for the response"           E302 "$(ts)"
# A subagent has its own cache: its events do not touch the main-thread state.
sub() {  # $1 = event, $2 = tool_input text
  printf '{"session_id":"%s","transcript_path":"%s","agent_id":"a1","hook_event_name":"%s","tool_input":"%s"}' \
    "$SID" "$TR" "$1" "${2:-}" |
    env -i PATH="$PATH" HOME="$HOM" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" \
      "$TEST_BASH" "$REPO/hooks/cache-touch.sh" "$1"
}
prompt p9 400; request 402; block a9 p9 405 m9 7000 0 0
sub PreToolUse;            check "subagent event → no read"              E302 "$(ts)"
hook PostToolUse '\"agent_id\"'
                           check "tool text with agent_id → main thread" E402 "$(ts)"

# ── Statusline countdown, notification and {miss} ─────────────────────────────
cat > "$TMP/in.json" <<EOF
{"cwd":"/tmp","session_id":"$SID","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
 "context_window":{"used_percentage":10,"current_usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}},
 "cost":{"total_cost_usd":0.1}}
EOF
tick() {  # FMT = format (default {cache}); extra args are env assignments
  local fmt='{cache}'
  [ -n "${FMT:-}" ] && fmt="$FMT"
  env -i PATH="$PATH" HOME="$HOM" USER=t HOSTNAME=h LANG="${LANG:-C.UTF-8}" CLAUDE_CONFIG_DIR="$CFG" \
    BURNBAR_FORMAT="$fmt" BURNBAR_COLS=200 BURNBAR_NOTIFY=none BURNBAR_FRESH_PRICES=0 \
    ${LEAD:+BURNBAR_NOTIFY_LEAD=$LEAD} ${CW:+BURNBAR_CACHE_WIDTH=$CW} "$@" \
    "$TEST_BASH" "$REPO/statusline.sh" < "$TMP/in.json"
}
# An exact countdown needs the timestamp and the tick in one second: runs "$@"
# again when the second changed meanwhile (a cold tick in Docker takes longer).
same_second() {
  local i=0 s out
  while [ "$i" -lt 5 ]; do
    s=$(date +%s)
    out=$("$@")
    [ "$(date +%s)" = "$s" ] && break
    i=$((i + 1))
  done
  echo "$out"
}
countdown_once() {  # 30 s after the last API call
  echo "$(( $(date +%s) - 30 ))" > "$TS"
  tick "$@" | sed 's/\x1b\[[0-9;]*m//g' | grep -o '[0-9-][0-9-]:[0-9-][0-9-]' | head -n 1
}
countdown() { same_second countdown_once "$@"; }

echo 3600 > "$TTL"; check "1h countdown"                    59:30 "$(countdown)"
echo 300  > "$TTL"; check "5m countdown"                    04:30 "$(countdown)"
rm -f "$TTL";       check "no TTL → no countdown"           --:-- "$(countdown)"
echo junk > "$TTL"; check "invalid TTL → no countdown"      --:-- "$(countdown)"
echo 300  > "$TTL"; check "BURNBAR_CACHE_TTL is ignored"    04:30 "$(countdown BURNBAR_CACHE_TTL=600)"

miss() { echo "$(( $(date +%s) - 30 ))" > "$TS"; FMT='{miss}' tick | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'miss:\$[0-9.]*' || echo empty; }
echo 300 > "$TTL";  check "{miss} with a known TTL"         'miss:$0.0000' "$(miss)"
rm -f "$TTL";       check "{miss} with no TTL → empty"      empty          "$(miss)"

# BURNBAR_CACHE_WIDTH=0: the colored countdown alone, no bar cells (grey bg 47
# or a color bg 41-43), no leading space. Also in the --:-- state (no API call).
# $1 = 1: last API call 30 s ago (fresh epoch, as in countdown), 0: none yet.
plain_once() { touch_ts "$1"; tick | sed 's/\x1b\[[0-9;]*m//g'; }
plain()     { same_second plain_once "$1"; }
bar_cells() { touch_ts "$1"; tick | grep -c $'\033\[4[1237]m'; }
touch_ts()  { if [ "$1" = 1 ]; then echo "$(( $(date +%s) - 30 ))" > "$TS"; else rm -f "$TS"; fi; }
echo 300 > "$TTL"
check "width 0 → countdown only"            04:30 "$(CW=0 plain 1)"
check "width 0 → no bar cells"              0     "$(CW=0 bar_cells 1)"
check "default width → bar cells"           1     "$(bar_cells 1)"
check "invalid width → default bar"         1     "$(CW=x bar_cells 1)"
# Expired: white on red on even seconds only. 4 ticks 0.5 s apart span over
# 1 s without a gap of 1 s: they see both parities, wherever the boundary falls.
flashes() {  # $1 = seconds since the last API call → "flashed/ticks"
  local n=0 i
  echo "$(( $(date +%s) - $1 ))" > "$TS"
  for i in 1 2 3 4; do
    tick | grep -q $'\033\[01;37;41m' && n=$((n + 1))
    [ "$i" -lt 4 ] && sleep 0.5
  done
  case "$n" in 0) echo never ;; 4) echo always ;; *) echo alternates ;; esac
}
check "warm cache → no flash"               never      "$(flashes 30)"
check "expired cache → 00:00 flashes"       alternates "$(flashes 400)"
check "width 0, no API call → --:--"        --:-- "$(CW=0 plain 0)"
check "width 0, no API call → no bar cells" 0     "$(CW=0 bar_cells 0)"

# BURNBAR_NOTIFY=none sends nothing but writes the sentinel (no tty needed):
# it shows if the notification fired. remaining = TTL - elapsed.
notified() {  # $1 = TTL (none = no file), $2 = elapsed
  rm -f "$CFG/.cache-notif-$KEY" "$TTL"; echo "$(( $(date +%s) - $2 ))" > "$TS"
  [ "$1" != none ] && echo "$1" > "$TTL"
  tick >/dev/null
  [ -f "$CFG/.cache-notif-$KEY" ] && echo yes || echo no
}
check "1h, 5:10 left → no notification"  no  "$(notified 3600 3290)"
check "1h, 4:50 left → notification"     yes "$(notified 3600 3310)"
check "5m, 2:40 left → no notification"  no  "$(notified 300 140)"
check "5m, 2:20 left → notification"     yes "$(notified 300 160)"
check "lead 600, 1h, 9:50 left → notification" yes "$(LEAD=600 notified 3600 3010)"
check "no TTL → no notification"         no  "$(notified none 160)"

exit "$fail"
