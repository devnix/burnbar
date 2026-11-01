#!/usr/bin/env bash
# Burnbar optional bars test.
#
# Every bar width accepts 0: the bar goes, the rest of the tag stays, and no
# stray space remains. A non-numeric width falls back to the default bar. An
# empty tag takes the spaces before it, so a format needs no change.
#
# Usage: tests/bars.sh
# Env:   TEST_BASH — bash binary under test (default: bash)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; HOM="$TMP/home"; mkdir -p "$CFG" "$HOM/.cache"
SID="barstest-0000-0000"; KEY="${SID:0:8}"
fail=0

check() {  # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

cat > "$TMP/in.json" <<EOF
{"cwd":"/tmp","session_id":"$SID","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
 "context_window":{"used_percentage":10,"current_usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}},
 "cost":{"total_cost_usd":1.1},
 "rate_limits":{"five_hour":{"used_percentage":50},"seven_day":{"used_percentage":25}}}
EOF
# Two recorded turns, no turn in progress: {delta} is the last recorded one.
echo m1 > "$CFG/.turn-ts-$KEY"; printf 'm1\n1.1\n0.5000 1.0000\n' > "$CFG/.cost-hist-$KEY"
# A fresh reading: no refresh job, so the credentials only open the gate.
SPEND="$HOM/.cache/burnbar-plan-spend-cfg"
echo '{}' > "$CFG/.credentials.json"

tick() {  # $1 = format, $2... = env assignments
  local fmt=$1; shift
  env -i PATH="$PATH" HOME="$HOM" USER=t HOSTNAME=h LANG="${LANG:-C.UTF-8}" CLAUDE_CONFIG_DIR="$CFG" \
    BURNBAR_FORMAT="$fmt" BURNBAR_COLS=400 BURNBAR_NOTIFY=none BURNBAR_FRESH_PRICES=0 BURNBAR_SPARK=blocks \
    BURNBAR_DAILY_BUDGET=20 "$@" "$TEST_BASH" "$REPO/statusline.sh" < "$TMP/in.json"
}
plain() { tick "$@" | sed 's/\x1b\[[0-9;]*m//g'; }
# Bar cells: a grey or color background. Any count above 0 prints "bar".
cells() { if tick "$@" 2>&1 | grep -q $'\033\[[0-9;]*4[1237]m'; then echo bar; else echo none; fi; }

printf '98.33|400.00|USD|1|%d|95.23|%s|3.10\n' "$(date +%s)" "$(date +%Y-%m-%d)" > "$SPEND"

# ── Each bar: default, width 0, invalid width ─────────────────────────────────
bar_case() {  # $1 = tag format, $2 = width var, $3 = expected plain text at width 0
  check "$2 default → bar"   bar  "$(cells "$1")"
  check "$2=0 → no bar"      none "$(cells "$1" "$2=0")"
  check "$2=0 → text"        "$3" "$(plain "$1" "$2=0")"
  check "$2=x → default bar" bar  "$(cells "$1" "$2=x")"
  check "$2=x → no error"    ""   "$(tick "$1" "$2=x" 2>&1 >/dev/null)"
}
bar_case '{ctx} {bar} {pct}' BURNBAR_BAR_WIDTH     'ctx:3 10%'
bar_case '{5h}'              BURNBAR_5H_WIDTH      '50%'
bar_case '{1w}'              BURNBAR_WEEKLY_WIDTH  '25%'
bar_case '{monthly}'         BURNBAR_MONTHLY_WIDTH 'mo:$98.33/$400 24.6%'
bar_case '{daily}'           BURNBAR_DAILY_WIDTH   'day:$3.10/$20 15.5%'
bar_case '{delta} {spark}|'  BURNBAR_SPARK_WIDTH   'delta:$1.0000|'

# A label group stays when only its bar goes.
check "[[5h: {5h}]] keeps its label" '5h: 50%' "$(plain '[[5h: {5h}]]' BURNBAR_5H_WIDTH=0)"

# ── Spaces around an empty tag ────────────────────────────────────────────────
check "two spaces before an empty tag" 'ctx:3  10%' "$(plain '{ctx}  {bar}  {pct}' BURNBAR_BAR_WIDTH=0)"
check "a non-empty tag keeps its space" 'ctx:3 10%' "$(plain '{ctx} {pct}')"

# Default format, all bars hidden: no bar, no doubled space, no space before a separator.
all0=(BURNBAR_BAR_WIDTH=0 BURNBAR_CACHE_WIDTH=0 BURNBAR_SPARK_WIDTH=0 BURNBAR_5H_WIDTH=0
      BURNBAR_WEEKLY_WIDTH=0 BURNBAR_MONTHLY_WIDTH=0 BURNBAR_DAILY_WIDTH=0 BURNBAR_WRAP_SEP='|')
default_fmt=$(sed -n "s/^_default_fmt='\(.*\)'$/\1/p" "$REPO/statusline.sh")
line=$(plain "$default_fmt" "${all0[@]}" | tail -n 1)
check "all at 0 → no bar"             none "$(cells "$default_fmt" "${all0[@]}")"
has() { if [[ "$line" == *"$1"* ]]; then echo yes; else echo no; fi; }
check "all at 0 → no doubled space"   no   "$(has '  ')"
check "all at 0 → no space before │"  no   "$(has ' │')"
check "all at 0 → delta stays"        yes  "$(has 'delta:$1.0000')"

# ── BURNBAR_SPARK_WIDTH=0 keeps the history ───────────────────────────────────
echo m2 > "$CFG/.turn-ts-$KEY"; printf 'm1\n0.6\n0.5000\n' > "$CFG/.cost-hist-$KEY"
check "width 0 records the turn" 'delta:$0.5000' "$(plain '{delta}{spark}' BURNBAR_SPARK_WIDTH=0)"
check "history gains the delta"  'm2|1.1|0.5000 0.5000|' "$(tr '\n' '|' < "$CFG/.cost-hist-$KEY")"

exit "$fail"
