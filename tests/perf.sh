#!/usr/bin/env bash
# Burnbar performance regression test.
#
# Runs statusline.sh in its steady state (fresh caches, no turn boundary, no
# background refresh) against a hermetic fixture, and fails when:
#   1. forks per tick exceed MAX_FORKS        (machine-independent; needs strace)
#   2. the CPU time per tick exceeds BUDGET_MS (machine-dependent; generous)
#
# Times are CPU time (user + sys of the tick and everything it waits for), not
# wall time: a loaded machine stretches wall time 2x and made a wall-clock
# budget flaky, while CPU time stays put.
#   3. 4x longer segments (bars 4x wider, one escape per cell) cost more than
#      MAX_SEG_RATIO x — catches super-linear escape handling. Today ~2-3x; the
#      old extglob strip (${var//\\033\[*([0-9;])[A-Za-z]/}) scored ~40x.
#   4. 4x more segments (the format body repeated) cost more than MAX_RATIO x —
#      catches super-linear layout. Today ~4x on bash 3.2; it was ~6-7x when
#      the tags were 16 ${var//pat/rep} passes over the growing line.
#
# No network: a credentials file exists (so {monthly}/{daily} render from the
# cache) but the plan cache is fresh, and curl/security are stubbed to fail.
# The price cache (fresh prices are on by default) is fresh too: the hot-path
# lookup runs, the download does not.
#
# Usage: tests/perf.sh
# Env:   PERF_RUNS (default 30)  PERF_BUDGET_MS (60; 90 on bash < 4.2)
#        PERF_MAX_FORKS (6; 8)  PERF_MAX_SEG_RATIO (8)  PERF_MAX_RATIO (5; 7)
#        PERF_BASH — bash binary under test (default: bash)
#        PERF_SCRIPT — statusline under test (default: ../statusline.sh)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${PERF_SCRIPT:-$REPO/statusline.sh}"
TEST_BASH="${PERF_BASH:-bash}"
RUNS="${PERF_RUNS:-30}"
# bash < 4.2 (stock macOS bash 3.2) has no strftime builtin: the tick's one
# date(1) call forks (+2 forks/tick), and its string ops are slower and
# noisier on shared runners. Separate defaults keep the test a regression
# guard on both, not a failure on the known 3.2 cost.
if [ "$("$TEST_BASH" -c 'echo $(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] ))')" -ge 402 ]; then
  _d_budget=60 _d_forks=6 _d_ratio=5
else
  _d_budget=90 _d_forks=8 _d_ratio=7
fi
BUDGET_MS="${PERF_BUDGET_MS:-$_d_budget}"
MAX_FORKS="${PERF_MAX_FORKS:-$_d_forks}"
MAX_SEG_RATIO="${PERF_MAX_SEG_RATIO:-8}"
MAX_RATIO="${PERF_MAX_RATIO:-$_d_ratio}"

# ── CPU clock (microseconds) ──────────────────────────────────────────────────
# `times` (builtin, no fork) line 2 = user and sys CPU of the waited-for
# children, e.g. "0m1.234s 0m0.056s" (a comma decimal in some locales).
# Both helpers set variables: a $(...) subshell would report its own (zero)
# children instead of ours.
_t2us() {  # $1 = "XmY.YYYs" → _us
  local m="${1%%m*}" s="${1#*m}" i f
  s="${s%s}"; i="${s%%[.,]*}"; f="${s#*[.,]}000000"; f="${f:0:6}"
  _us=$(( (10#$m * 60 + 10#$i) * 1000000 + 10#$f ))
}
_cpu_us() {  # → _cpu
  local _ u sy
  times > "$TMP/times"
  { read -r _; read -r u sy; } < "$TMP/times"
  _t2us "$u"; _cpu=$_us
  _t2us "$sy"; _cpu=$(( _cpu + _us ))
}

# ── Hermetic fixture ──────────────────────────────────────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; HOM="$TMP/home"; BIN="$TMP/bin"
mkdir -p "$CFG" "$HOM/.cache" "$BIN"
for _stub in curl security; do printf '#!/bin/sh\nexit 1\n' > "$BIN/$_stub"; chmod +x "$BIN/$_stub"; done

NOW=$(date +%s); SID="perftest-0000-0000"; KEY="${SID:0:8}"; TODAY=$(date +%F)
echo '{"claudeAiOauth":{"accessToken":"x","expiresAt":9999999999999}}' > "$CFG/.credentials.json"
echo "$(( NOW - 30 ))" > "$CFG/.cache-ts-$KEY"                     # cache timer mid-TTL
echo 3600 > "$CFG/.cache-ttl-$KEY"                                  # TTL read by the hook
echo "m1" > "$CFG/.turn-ts-$KEY"                                    # == history marker:
printf 'm1\n1.0000\n%s\n' "0.0100 0.0500 0.1200 0.0300 0.2500 0.0800 0.0150 0.3100 \
0.0400 0.0900 0.1700 0.0200 0.0600 0.2200 0.1100 0.0350" > "$CFG/.cost-hist-$KEY"  # no rewrite
echo "92.37|400.00|USD|1|$(( NOW + 86400 ))|91.32|$TODAY|1.05" \
  > "$HOM/.cache/burnbar-plan-spend-cfg"                            # never stale → no fetch
# Fresh price cache, the fixture model last (the lookup scans every line) at a
# price unlike the table's, so the sanity check proves the hit path ran.
{ echo "$NOW"
  for _m in haiku-4-5 opus-4-5 sonnet-4-5 fable-5-1 opus-5 fable-5 opus-4-8 sonnet-5 \
            opus-4-6 haiku-5-5 sonnet-4-6 sonnet-5-5 opus-4-7; do echo "claude-$_m 3 0 0"; done
  echo "claude-opus-5-5 5 0 0"; } > "$HOM/.cache/burnbar-prices"

cat > "$TMP/in.json" <<EOF
{"cwd":"/home/user/dev/project","session_id":"$SID",
 "model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
 "effort":{"level":"high"},
 "context_window":{"used_percentage":47.3,
   "current_usage":{"input_tokens":1200,"cache_creation_input_tokens":3400,"cache_read_input_tokens":88000}},
 "cost":{"total_cost_usd":1.9450},
 "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":$(( NOW + 7200 ))},
                "seven_day":{"used_percentage":41,"resets_at":$(( NOW + 200000 ))}}}
EOF

DEFAULT_FMT=$(sed -n "s/^_default_fmt='\(.*\)'$/\1/p" "$SCRIPT")
[ -n "$DEFAULT_FMT" ] || { echo "perf.sh: cannot read _default_fmt from statusline.sh" >&2; exit 2; }
BODY="${DEFAULT_FMT#*\\n}"                       # format without the header line
FMT4="${DEFAULT_FMT}{sep}${BODY}{sep}${BODY}{sep}${BODY}"

tick() {  # [prefix cmd...] -- $1 = format, $2 = columns, $3 = bar width (default 8)
  local pre=() w
  while [ "$1" != "--" ]; do pre+=("$1"); shift; done; shift
  w="${3:-8}"
  # ${a[@]+"${a[@]}"}: on bash < 4.4 an empty "${pre[@]}" trips set -u.
  ${pre[@]+"${pre[@]}"} env -i PATH="$BIN:$PATH" HOME="$HOM" USER=perf HOSTNAME=perfhost LANG="${LANG:-C.UTF-8}" \
    CLAUDE_CONFIG_DIR="$CFG" BURNBAR_FORMAT="$1" BURNBAR_COLS="$2" BURNBAR_NOTIFY=none \
    BURNBAR_BAR_WIDTH="$(( w * 5 / 2 ))" BURNBAR_CACHE_WIDTH="$w" BURNBAR_5H_WIDTH="$w" \
    BURNBAR_WEEKLY_WIDTH="$w" BURNBAR_SPARK_WIDTH="$w" \
    "$TEST_BASH" "$SCRIPT" < "$TMP/in.json"
}

cpu_ms() {  # $1 = format, $2 = columns, $3 = bar width → mean CPU ms per tick
  local i c0 c1
  _cpu_us; c0=$_cpu; tick -- "$@" >/dev/null; _cpu_us; c1=$_cpu   # warm-up
  # A pathological tick (> 1 s) is the answer already: don't run it RUNS times.
  if [ $(( c1 - c0 )) -gt 1000000 ]; then
    awk -v u=$(( c1 - c0 )) 'BEGIN{printf "%.1f", u/1000}'; return
  fi
  _cpu_us; c0=$_cpu
  for (( i = 0; i < RUNS; i++ )); do tick -- "$@" >/dev/null; done
  _cpu_us; c1=$_cpu
  awk -v u=$(( c1 - c0 )) -v n="$RUNS" 'BEGIN{printf "%.1f", u/n/1000}'
}

fail=0
check() {  # $1 = label, $2 = ok (0/1), $3 = detail
  if [ "$2" = 1 ]; then printf '  ok    %-40s %s\n' "$1" "$3"
  else printf '  FAIL  %-40s %s\n' "$1" "$3"; fail=1; fi
}

echo "Burnbar perf — $("$TEST_BASH" -c 'echo bash $BASH_VERSION'), $RUNS runs"

# Sanity: the fixture renders every data tag (an empty tag would hide its cost).
out=$(tick -- "$DEFAULT_FMT" 300 | sed 's/\x1b\[[0-9;]*m//g')
for want in 'ctx:' 'miss:$0.9260' 'total:' 'cache:' 'delta:' '5h:' '1w:' 'mo:$92.37' 'day:$1.05'; do
  [[ "$out" == *"$want"* ]] || { echo "  FAIL  fixture: '$want' missing from output"; fail=1; }
done

# 1. Forks per tick.
if command -v strace >/dev/null 2>&1; then
  # env execs the bash under test, so every fork counted is the script's own.
  tick strace -f -qq -e trace=clone,clone3,fork,vfork -o "$TMP/strace" -- "$DEFAULT_FMT" 300 >/dev/null 2>&1
  forks=$(grep -cE 'clone|fork' "$TMP/strace")
  check "forks per tick <= $MAX_FORKS" "$(( forks <= MAX_FORKS ))" "$forks"
else
  echo "  skip  forks per tick (strace not installed)"
fi

# 2. Wall time budget, wide (one line) and narrow (every {sep} wraps).
for cols in 300 60; do
  ms=$(cpu_ms "$DEFAULT_FMT" "$cols")
  check "CPU/tick ${cols} cols <= ${BUDGET_MS} ms" "$(awk -v m="$ms" -v b="$BUDGET_MS" 'BEGIN{print (m<=b)}')" "${ms} ms"
done

ratio_check() {  # $1 = label, $2 = max ratio, $3 = base ms, $4 = scaled ms
  local r
  case "$3$4" in ''|*[!0-9.]*) check "$1 <= ${2}x" 0 "no measurement"; return ;; esac
  [ "$3" = 0.0 ] && { check "$1 <= ${2}x" 0 "no measurement (0 ms)"; return; }
  r=$(awk -v a="$3" -v b="$4" 'BEGIN{printf "%.2f", b/a}')
  check "$1 <= ${2}x" "$(awk -v r="$r" -v x="$2" 'BEGIN{print (r<=x)}')" "${3} → ${4} ms (x${r})"
}

# 3. Segment length: bars 4x wider.
for cols in 1000 60; do
  ratio_check "4x segment length (${cols} cols)" "$MAX_SEG_RATIO" \
    "$(cpu_ms "$DEFAULT_FMT" "$cols" 8)" "$(cpu_ms "$DEFAULT_FMT" "$cols" 32)"
done

# 4. Segment count: the format body repeated 4x.
for cols in 1000 60; do
  ratio_check "4x segment count (${cols} cols)" "$MAX_RATIO" \
    "$(cpu_ms "$DEFAULT_FMT" "$cols")" "$(cpu_ms "$FMT4" "$cols")"
done

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
