#!/usr/bin/env bash
# Burnbar effort-alert test.
#
# "⚠ effort" shows when the effort changed since the last API call, but only
# on the models where an effort change rewrites the cache. Claude Code sends
# the change as a per-turn message on the newer models: there the cache stays.
#
# Usage: tests/effort-alert.sh
# Env:   TEST_BASH — bash binary under test (default: bash)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; HOM="$TMP/home"; mkdir -p "$CFG" "$HOM"
SID="efftest-0000-0000"; KEY="${SID:0:8}"
echo 3600 > "$CFG/.cache-ttl-$KEY"  # the alert shows only with a known TTL
fail=0

check() {  # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

# $1 = model id, $2 = model (id, or a legacy family) and $3 = effort of the last
# API call, $4 = current effort; extra args are env assignments. Prints the
# alert word, or "none".
alert() {
  local model=$1 family=$2 was=$3 now=$4 last
  shift 4
  last=$(( $(date +%s) - 30 ))
  echo "$last" > "$CFG/.cache-ts-$KEY"
  echo "$last|$family|$was" > "$CFG/.cache-meta-$KEY"
  render "$model" "$now" "$@"
}

# $1 = current model id, $2 = current effort; extra args are env assignments.
render() {
  local model=$1 now=$2
  shift 2
  printf '{"cwd":"/tmp","session_id":"%s","model":{"id":"%s","display_name":"M"},"effort":{"level":"%s"},"context_window":{"used_percentage":10},"cost":{"total_cost_usd":0.1}}' \
    "$SID" "$model" "$now" |
    env -i PATH="$PATH" HOME="$HOM" USER=t HOSTNAME=h LANG="${LANG:-C.UTF-8}" CLAUDE_CONFIG_DIR="$CFG" \
      BURNBAR_FORMAT='{cache}' BURNBAR_COLS=200 BURNBAR_NOTIFY=none "$@" \
      "$TEST_BASH" "$REPO/statusline.sh" |
    grep -o '⚠ [a-z]*' | head -n 1 | sed 's/⚠ //' | grep . || echo none
}

check "Opus 5, effort changed → alert"        effort "$(alert claude-opus-5 opus high low)"
check "Opus 4.8, effort changed → alert"      effort "$(alert claude-opus-4-8 opus high low)"
check "Sonnet 4.6 [1m] → alert"               effort "$(alert 'claude-sonnet-4-6[1m]' sonnet high low)"
check "Fable 5 → alert"                       effort "$(alert claude-fable-5 fable high low)"
check "Bedrock Opus 4.6 → alert"              effort "$(alert us.anthropic.claude-opus-4-6-v1 opus high low)"
check "Opus 4.5 (dated) → alert"              effort "$(alert claude-opus-4-5-20251101 opus high low)"
check "Mythos 5 → alert"                      effort "$(alert claude-mythos-5 fable high low)"
check "Mythos 5.1 → alert"                    effort "$(alert claude-mythos-5-1 fable high low)"
check "Sonnet 4.5 (no effort sent) → none"    none   "$(alert claude-sonnet-4-5-20250929 sonnet high low)"
check "Opus 4.1 (no effort sent) → none"      none   "$(alert claude-opus-4-1-20250805 opus high low)"
check "Opus 5.5 → no alert (per-turn effort)" none   "$(alert claude-opus-5-5 opus high low)"
check "Fable 5.1 → no alert"                  none   "$(alert claude-fable-5-1 fable high low)"
check "Sonnet 5.5 → no alert"                 none   "$(alert claude-sonnet-5-5 sonnet high low)"
check "Haiku 5.5 → no alert"                  none   "$(alert claude-haiku-5-5 haiku medium low)"
check "Opus 5, same effort → no alert"        none   "$(alert claude-opus-5 opus high high)"
check "Opus 5.5 on Vertex → alert"            effort "$(alert claude-opus-5-5 opus high low CLAUDE_CODE_USE_VERTEX=1)"
check "Opus 5.5 on Bedrock → alert"           effort "$(alert claude-opus-5-5 opus high low CLAUDE_CODE_USE_BEDROCK=1)"
check "Opus 5.5 on Bedrock Mantle → no alert" none   "$(alert claude-opus-5-5 opus high low CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_MANTLE=1)"
check "Opus 5.5, betas off → alert"           effort "$(alert claude-opus-5-5 opus high low CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1)"
check "family change → model alert"          model  "$(alert claude-opus-5-5 claude-sonnet-5-5 high low)"
check "Sonnet 4.6 → 5.5 → model alert"        model  "$(alert claude-sonnet-5-5 claude-sonnet-4-6 low low)"
check "Opus 5 → 5.5 → model alert"            model  "$(alert claude-opus-5-5 claude-opus-5 high high)"
check "[1m] on native 1M → no alert"          none   "$(alert 'claude-opus-5-5[1m]' claude-opus-5-5 high high)"
check "Sonnet 4.6 → [1m] → model alert"       model  "$(alert 'claude-sonnet-4-6[1m]' claude-sonnet-4-6 low low)"
check "Sonnet 4.6 [1m] → [1m] → no alert"     none   "$(alert 'claude-sonnet-4-6[1m]' 'claude-sonnet-4-6[1m]' low low)"
check "legacy meta, same family → no alert"   none   "$(alert claude-opus-5-5 opus high high)"
check "legacy meta, new family → model alert" model  "$(alert claude-opus-5-5 sonnet high high)"

# ── Baseline from the hook: the model of the last API call ────────────────────
# A switch during a turn changes the statusline model, not the model of the
# calls already made: the hook reads that model from the transcript.
TR="$TMP/transcript.jsonl"
hook() {  # $1 = event
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"%s"}' "$SID" "$TR" "$1" |
    env -i PATH="$PATH" HOME="$HOM" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SID" \
      "$TEST_BASH" "$REPO/hooks/cache-touch.sh" "$1"
}
# One API call that read the cache, 10 s after the previous one: the
# statusline sees a new epoch. A tool input with its own "model" key.
T=$(( $(date +%s) - 600 )); N=0
call() {  # $1 = model of the API call
  local ts
  T=$((T + 10)); N=$((N + 1))
  ts=$(date -u -d "@$T" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$T" +%Y-%m-%dT%H:%M:%S.000Z)
  printf '{"isSidechain":false,"type":"assistant","uuid":"a%d","timestamp":"%s","message":{"id":"m%d","model":"%s","usage":{"cache_read_input_tokens":100},"content":[{"type":"tool_use","input":{"model":"x-claude-y"}}]}}\n' \
    "$N" "$ts" "$N" "$1" >> "$TR"
}
rm -f "$CFG/.cache-meta-$KEY" "$CFG/.cache-ts-$KEY"; : > "$TR"
call claude-opus-5; hook PreToolUse
check "switch during the turn → model alert"  model "$(render claude-opus-5-5 high)"
check "alert stays on the next tick"          model "$(render claude-opus-5-5 high)"
hook UserPromptSubmit
check "prompt is not evidence → alert stays"  model "$(render claude-opus-5-5 high)"
call claude-opus-5-5; hook Stop
check "call made by the current model → none" none  "$(render claude-opus-5-5 high)"
call claude-sonnet-4-6; hook Stop
check "transcript id vs [1m] id → no alert"   none  "$(render 'claude-sonnet-4-6[1m]' high)"
call claude-opus-4-6; hook PreToolUse
check "Bedrock id vs transcript id → none"    none  "$(render us.anthropic.claude-opus-4-6-v1 high)"
rm -f "$TR" "$CFG/.cache-ts-$KEY"; hook PreToolUse
check "no transcript → no timestamp"          no    "$([ -f "$CFG/.cache-ts-$KEY" ] && echo yes || echo no)"

exit "$fail"
