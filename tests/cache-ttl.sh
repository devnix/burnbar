#!/usr/bin/env bash
# Burnbar cache TTL test.
#
# The cache-touch hook detects the prompt-cache TTL (5m or 1h) from the last
# main-thread cache write in the transcript, after each API call (PostToolUse,
# Stop), and writes it to .cache-ttl-<key>. The statusline uses it for the
# {cache} countdown and caps the notification lead time at 50% of it.
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

usage_line() {  # $1 = 5m tokens, $2 = 1h tokens, $3 = isSidechain (default false)
  printf '{"isSidechain":%s,"type":"assistant","message":{"usage":{"cache_creation_input_tokens":%d,"cache_creation":{"ephemeral_1h_input_tokens":%d,"ephemeral_5m_input_tokens":%d}}}}\n' \
    "${3:-false}" "$(( $1 + $2 ))" "$2" "$1" >> "$TR"
}

ttl() { local t=""; [ -f "$TTL" ] && read -r t < "$TTL"; echo "${t:-none}"; }

# ── Hook detection ────────────────────────────────────────────────────────────
: > "$TR"
hook PostToolUse;                          check "no usage yet → no TTL"      none "$(ttl)"
usage_line 0 1200;  hook PostToolUse;      check "1h write on PostToolUse"    3600 "$(ttl)"
usage_line 800 0;   hook UserPromptSubmit; check "prompt does not detect"     3600 "$(ttl)"
hook Stop;                                 check "5m write on Stop"           300  "$(ttl)"
usage_line 0 0;     hook PostToolUse;      check "cache read only keeps"      300  "$(ttl)"
usage_line 0 900 true; hook PostToolUse;   check "subagent write is ignored"  300  "$(ttl)"
usage_line 500 900; hook PostToolUse;      check "mixed write → 1h"           3600 "$(ttl)"
# A large tool_response: the hook reads only the head of its stdin.
big=$(head -c 1048576 /dev/zero | tr '\0' a)
usage_line 600 0;   hook PostToolUse "$big"; check "1 MB tool_response"       300  "$(ttl)"
rm -f "$TR";        hook Stop;             check "missing transcript keeps"   300  "$(ttl)"

# ── Statusline countdown and notification lead ────────────────────────────────
cat > "$TMP/in.json" <<EOF
{"cwd":"/tmp","session_id":"$SID","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
 "context_window":{"used_percentage":10,"current_usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}},
 "cost":{"total_cost_usd":0.1}}
EOF
tick() {
  env -i PATH="$PATH" HOME="$HOM" USER=t HOSTNAME=h LANG="${LANG:-C.UTF-8}" CLAUDE_CONFIG_DIR="$CFG" \
    BURNBAR_FORMAT='{cache}' BURNBAR_COLS=200 BURNBAR_NOTIFY=none \
    ${LEAD:+BURNBAR_NOTIFY_LEAD=$LEAD} ${OVR:+BURNBAR_CACHE_TTL=$OVR} ${CW:+BURNBAR_CACHE_WIDTH=$CW} \
    "$TEST_BASH" "$REPO/statusline.sh" < "$TMP/in.json"
}
countdown() {  # 30 s after the last API call; fresh epoch so a second boundary cannot shift it
  echo "$(( $(date +%s) - 30 ))" > "$TS"
  tick | grep -o '[0-9][0-9]:[0-9][0-9]' | head -n 1
}

echo 3600 > "$TTL"; check "1h countdown"             59:30 "$(countdown)"
echo 300  > "$TTL"; check "5m countdown"             04:30 "$(countdown)"
rm -f "$TTL";       check "no TTL file → 5m"         04:30 "$(countdown)"
echo junk > "$TTL"; check "invalid TTL → 5m"         04:30 "$(countdown)"
check "BURNBAR_CACHE_TTL overrides"                  09:30 "$(OVR=600 countdown)"

# BURNBAR_CACHE_WIDTH=0: the colored countdown alone, no bar cells (grey bg 47
# or a color bg 41-43), no leading space. Also in the --:-- state (no API call).
# $1 = 1: last API call 30 s ago (fresh epoch, as in countdown), 0: none yet.
plain()     { touch_ts "$1"; tick | sed 's/\x1b\[[0-9;]*m//g'; }
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
notified() {  # $1 = TTL, $2 = elapsed
  rm -f "$CFG/.cache-notif-$KEY"; echo "$(( $(date +%s) - $2 ))" > "$TS"; echo "$1" > "$TTL"
  tick >/dev/null
  [ -f "$CFG/.cache-notif-$KEY" ] && echo yes || echo no
}
check "1h, 5:10 left → no notification"  no  "$(notified 3600 3290)"
check "1h, 4:50 left → notification"     yes "$(notified 3600 3310)"
check "5m, 2:40 left → no notification"  no  "$(notified 300 140)"
check "5m, 2:20 left → notification"     yes "$(notified 300 160)"
check "lead 600, 1h, 9:50 left → notification" yes "$(LEAD=600 notified 3600 3010)"

exit "$fail"
