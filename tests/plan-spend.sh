#!/usr/bin/env bash
# Burnbar billed-spend test ({monthly}, {daily}).
#
# A reading older than PLAN_STALE_AGE (15 min) is still shown, with a "~"
# before the amounts. A failed refresh keeps the lock, and the lock holds the
# number of attempts since the last success: the wait before the next attempt
# doubles from 5 min up to 1 h. A success removes the lock (count reset).
#
# Usage: tests/plan-spend.sh
# Env:   TEST_BASH — bash binary under test (default: bash)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; HOM="$TMP/home"; BIN="$TMP/bin"
CACHE="$HOM/.cache/burnbar-plan-spend-cfg"; LOCK="$CACHE.lock"
CALLS="$TMP/curl-calls"
mkdir -p "$CFG" "$BIN"
NOW=$(date +%s)
fail=0

check() {  # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

# curl stub: logs one line per call; prints $CURL_BODY, or fails as curl -f
# does on a 429 when it is empty.
cat > "$BIN/curl" <<EOF
#!/bin/sh
echo call >> "$CALLS"
[ -n "\${CURL_BODY:-}" ] || exit 22
cat "\$CURL_BODY"
EOF
chmod +x "$BIN/curl"
# macOS reads the token from the Keychain: the security stub prints the file.
printf '#!/bin/sh\ncat "%s/.credentials.json"\n' "$CFG" > "$BIN/security"; chmod +x "$BIN/security"
echo '{"claudeAiOauth":{"accessToken":"x","expiresAt":9999999999999}}' > "$CFG/.credentials.json"
echo '{"spend":{"enabled":true,"used":{"amount_minor":10050,"exponent":2,"currency":"USD"},"limit":{"amount_minor":40000,"exponent":2}}}' \
  > "$TMP/ok.json"

reset() { rm -rf "$HOM" "$CALLS"; mkdir -p "$HOM/.cache"; }
calls() { local n=0; [ -f "$CALLS" ] && n=$(wc -l < "$CALLS"); echo $(( n )); }
lock()  { local n=""; [ -f "$LOCK" ] && read -r n < "$LOCK"; echo "${n:-none}"; }
# The reading's day is today unless $2 is given, so a run near midnight does
# not move a recent reading to yesterday.
cache_at() {  # $1 = reading age (s), $2 = reading day (default: today)
  printf '98.33|400.00|USD|1|%d|95.23|%s|3.10\n' "$(( NOW - $1 ))" "${2:-$(date +%Y-%m-%d)}" > "$CACHE"
}
age_lock() {  # $1 = lock age (s); portable touch (BSD on macOS)
  local _t=$(( $(date +%s) - $1 ))
  touch -t "$(date -r "$_t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$_t" +%Y%m%d%H%M.%S)" "$LOCK"
}

# Prints the format without the escapes. Extra args are env assignments.
render() {
  echo '{"cwd":"/tmp","session_id":"spendtst-0000"}' |
    env -i PATH="$BIN:$PATH" HOME="$HOM" USER=t HOSTNAME=h LANG="${LANG:-C.UTF-8}" CLAUDE_CONFIG_DIR="$CFG" \
      BURNBAR_FORMAT='{monthly} {daily}' BURNBAR_COLS=200 BURNBAR_NOTIFY=none "$@" \
      "$TEST_BASH" "$REPO/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g'
}
amounts() { render "$@" | grep -o '[a-z]*:~\{0,1\}\$[0-9.]*' | tr '\n' ' ' | sed 's/ $//'; }

wait_for() {  # $1 = test expression; waits up to 10 s
  local _
  for _ in $(seq 1 50); do eval "$1" && return 0; sleep 0.2; done
  return 1
}
# The job runs in the background: wait until its curl call is logged, then
# until it exits (a success removes the lock).
wait_calls() {  # $1 = expected curl calls
  wait_for '[ "$(calls)" -ge '"$1"' ]'; sleep 0.3
}

# ── Display ───────────────────────────────────────────────────────────────────
# A fresh lock holds back the refresh: a job still running after the next
# reset (slow runners) would log its curl call into the backoff counts.
reset; cache_at 60
check "fresh reading → plain"          'mo:$98.33 day:$3.10'   "$(amounts)"
check "fresh reading → no refresh"     0                       "$(calls)"
reset; cache_at 600; echo 1 > "$LOCK"
check "10 min → plain"                 'mo:$98.33 day:$3.10'   "$(amounts CURL_BODY=)"
reset; cache_at 1000; echo 1 > "$LOCK"
check "over 15 min → stale marker"     'mo:~$98.33 day:~$3.10' "$(amounts CURL_BODY=)"
reset; cache_at 86400 2000-01-01; echo 1 > "$LOCK"
check "1 day old → still shown"        'mo:~$98.33 day:~$0.00' "$(amounts CURL_BODY=)"
reset; cache_at 1000; echo 1 > "$LOCK"
check "stale with budget bars"         'mo:~$98.33/$400 day:~$3.10/$20' \
  "$(render CURL_BODY= BURNBAR_DAILY_BUDGET=20 | grep -o '[a-z]*:~\{0,1\}\$[0-9.]*/\$[0-9]*' | tr '\n' ' ' | sed 's/ $//')"
check "held lock → no refresh"         0                       "$(calls)"

# ── Backoff ───────────────────────────────────────────────────────────────────
reset; cache_at 1000
render CURL_BODY= >/dev/null; wait_calls 1
check "429 → 1 call"                   1    "$(calls)"
check "429 → lock holds 1 attempt"     1    "$(lock)"
check "429 → cache kept"               98.33 "$(cut -d'|' -f1 "$CACHE")"
render CURL_BODY= >/dev/null; sleep 0.5
check "next tick → no call"            1    "$(calls)"
check "next tick → lock unchanged"      1    "$(lock)"
age_lock 301; render CURL_BODY= >/dev/null; wait_calls 2
check "after 5 min → 2nd call"         2    "$(calls)"
check "lock holds 2 attempts"          2    "$(lock)"
age_lock 301; render CURL_BODY= >/dev/null; sleep 0.5
check "2nd wait is 10 min → no call"   2    "$(calls)"
check "2nd wait → lock unchanged"       2    "$(lock)"
age_lock 601; render CURL_BODY= >/dev/null; wait_calls 3
check "after 10 min → 3rd call"        3    "$(calls)"
echo 9 > "$LOCK"; age_lock 3599; render CURL_BODY= >/dev/null; sleep 0.5
check "wait capped at 1 h → no call"   3    "$(calls)"
check "capped wait → lock unchanged"    9    "$(lock)"
age_lock 3601; render CURL_BODY= >/dev/null; wait_calls 4
check "after 1 h → 4th call"           4    "$(calls)"
check "lock holds 10 attempts"         10   "$(lock)"
: > "$LOCK"; age_lock 299; render CURL_BODY= >/dev/null; sleep 0.5
check "empty (old) lock → 5 min wait"  4    "$(calls)"
check "empty lock → unchanged"          yes  "$([ -f "$LOCK" ] && [ ! -s "$LOCK" ] && echo yes)"
age_lock 301; render CURL_BODY="$TMP/ok.json" >/dev/null; wait_calls 5
wait_for '[ ! -f "$LOCK" ]'
check "success → lock removed"         none "$(lock)"
check "success → cache updated"        100.50 "$(cut -d'|' -f1 "$CACHE")"
check "success → plain"                'mo:$100.50' "$(amounts | cut -d' ' -f1)"

exit "$fail"
