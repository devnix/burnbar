#!/usr/bin/env bash
# Burnbar live turn delta test.
#
# While a turn runs, {delta} and the last {spark} column show the cost since
# the last turn boundary (total - baseline) and grow with it. The Stop hook
# records that delta in the same slot. The live value is never persisted.
#
# Usage: tests/live-delta.sh
# Env:   TEST_BASH — bash binary under test (default: bash)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; HOM="$TMP/home"; mkdir -p "$CFG" "$HOM"
SID="livetest-0000-0000"; KEY="${SID:0:8}"
TURN="$CFG/.turn-ts-$KEY"; HIST="$CFG/.cost-hist-$KEY"
fail=0

check() {  # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

tick() {  # $1 = total cost, $2 = spark mode (default blocks) → "{delta}{spark}" without escapes/spaces
  printf '{"cwd":"/tmp","session_id":"%s","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"used_percentage":10,"current_usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}},"cost":{"total_cost_usd":%s}}' \
    "$SID" "$1" |
    env -i PATH="$PATH" HOME="$HOM" USER=t HOSTNAME=h LANG="${LANG:-C.UTF-8}" CLAUDE_CONFIG_DIR="$CFG" \
      BURNBAR_FORMAT='{delta}{spark}' BURNBAR_COLS=200 BURNBAR_NOTIFY=none \
      BURNBAR_SPARK="${2:-blocks}" BURNBAR_SPARK_WIDTH=4 \
      "$TEST_BASH" "$REPO/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g' | tr -d ' '
}

hist() { tr '\n' '|' < "$HIST"; }

# Tracking start: no history → baseline seeded, no live column.
rm -f "$TURN" "$HIST"
check "tracking start"              'delta:$0.0000'   "$(tick 1.1)"
check "baseline seeded"             '|1.1||'          "$(hist)"

# One recorded turn of $0.50, then a turn in progress.
echo m1 > "$TURN"; printf 'm1\n1.1\n0.5000\n' > "$HIST"
check "live column, half the max"   'delta:$0.2500█▄' "$(tick 1.35)"
check "live column grows"           'delta:$0.5000██' "$(tick 1.6)"
check "live is not persisted"       'm1|1.1|0.5000|'  "$(hist)"
check "live becomes the max"        'delta:$1.0000▄█' "$(tick 2.1)"
live_braille=$(tick 2.1 braille)

# Stop: the recorded delta takes the live slot.
echo m2 > "$TURN"
check "braille: no shift at Stop"   "$live_braille"   "$(tick 2.1 braille)"
check "history gains the delta"     'm2|2.1|0.5000 1.0000|' "$(hist)"
check "idle: last recorded delta"   'delta:$1.0000▄█' "$(tick 2.1)"

# Cost below the baseline (should not happen): no live column.
check "total < baseline"            'delta:$1.0000▄█' "$(tick 1.1)"

exit "$fail"
