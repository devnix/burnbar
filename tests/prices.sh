#!/usr/bin/env bash
# Burnbar fresh-prices test (on by default, BURNBAR_FRESH_PRICES=0 turns it off).
#
# The background job keeps the base input prices of .anthropic.models, keyed
# by _model_key. The hot path overrides the built-in table on a hit, and falls
# back to it on a miss, a stale cache, a corrupt line, or with BURNBAR_FRESH_PRICES=0.
# A failed download keeps the old cache and the lock (the retry backoff).
#
# {miss} = 100K context tokens × price × 1.25 (5m TTL) → $0.125 per $1/MTok.
#
# Usage: tests/prices.sh
# Env:   TEST_BASH — bash binary under test (default: bash)

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BASH="${TEST_BASH:-bash}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; HOM="$TMP/home"; BIN="$TMP/bin"
CACHE="$HOM/.cache/burnbar-prices"; LOCK="$CACHE.lock"
mkdir -p "$CFG" "$BIN"
echo 300 > "$CFG/.cache-ttl-pricetst"  # a 5m TTL: {miss} is empty while the TTL is unknown
NOW=$(date +%s)
fail=0

check() {  # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}

# curl stub: prints $CURL_BODY, fails when it is empty.
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
[ -n "${CURL_BODY:-}" ] || exit 22
cat "$CURL_BODY"
EOF
chmod +x "$BIN/curl"

# Trimmed models.dev catalog. The Claude entry under another provider has
# another price and must be ignored.
cat > "$TMP/api.json" <<'EOF'
{
  "anthropic": {"models": {
    "claude-opus-5-5":          {"cost": {"input": 4, "output": 20}},
    "claude-opus-4-5-20251101": {"cost": {"input": 5, "output": 25}},
    "claude-haiku-5-5":         {"cost": {"input": 0.1, "output": 0.5,
      "tiers": [{"input": 0.5, "output": 2.5, "tier": {"type": "context", "size": 100000}}]}},
    "claude-quill-6":           {"cost": {"input": 6, "output": 30}},
    "claude-broken":            {"cost": {"input": "n/a"}}
  }},
  "other-cloud": {"models": {"claude-opus-5-5": {"cost": {"input": 99}}}}
}
EOF
echo 'not json' > "$TMP/garbage.json"

reset() { rm -rf "$HOM"; mkdir -p "$HOM/.cache"; }

# $1 = model id, $2 = context tokens; extra args are env assignments. Prints
# the {miss} text without the escapes.
render() {
  local model=$1 toks=$2
  shift 2
  printf '{"cwd":"/tmp","session_id":"pricetst-0000","model":{"id":"%s"},"context_window":{"current_usage":{"input_tokens":%s}}}' \
    "$model" "$toks" |
    env -i PATH="$BIN:$PATH" HOME="$HOM" USER=t HOSTNAME=h LANG="${LANG:-C.UTF-8}" CLAUDE_CONFIG_DIR="$CFG" \
      BURNBAR_FORMAT='{miss}' BURNBAR_COLS=200 BURNBAR_NOTIFY=none "$@" \
      "$TEST_BASH" "$REPO/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g; s/^miss://'
}

wait_for() {  # $1 = test expression; waits up to 10 s
  local _
  for _ in $(seq 1 50); do eval "$1" && return 0; sleep 0.2; done
  return 1
}

# ── Download ──────────────────────────────────────────────────────────────────
reset
render claude-opus-5-5 100000 CURL_BODY="$TMP/api.json" >/dev/null
wait_for '[ -f "$CACHE" ] && [ ! -f "$LOCK" ]'
check "download writes the cache, removes the lock" "yes" "$([ -f "$CACHE" ] && [ ! -f "$LOCK" ] && echo yes)"
check "dated id → _model_key"       "claude-opus-4-5 5 0 0"           "$(grep '^claude-opus-4-5 ' "$CACHE")"
check "long-context tier kept"      "claude-haiku-5-5 0.1 100000 0.5" "$(grep '^claude-haiku-5-5 ' "$CACHE")"
check "other provider ignored"      "claude-opus-5-5 4 0 0"           "$(grep '^claude-opus-5-5 ' "$CACHE")"
check "non-numeric price dropped"   ""                                "$(grep '^claude-broken' "$CACHE")"

# ── Lookup ────────────────────────────────────────────────────────────────────
reset
printf '%s\n' "$NOW" "claude-opus-5-5 40 0 0" "claude-haiku-5-5 0.1 100000 0.5" \
  "claude-quill-6 6 0 0" "claude-sonnet-5 junk 0 0" > "$CACHE"
check "hit overrides the table"     '$5.0000'  "$(render claude-opus-5-5 100000)"
check "[1m] id hits"                '$5.0000'  "$(render 'claude-opus-5-5[1m]' 100000)"
check "Bedrock id hits"             '$5.0000'  "$(render 'us.anthropic.claude-opus-5-5-v1:0' 100000)"
check "Vertex id hits"              '$5.0000'  "$(render 'claude-opus-5-5@20260101' 100000)"
check "long-context tier applies"   '$0.1250'  "$(render claude-haiku-5-5 200000)"
check "new family gets a price"     '$0.7500'  "$(render claude-quill-6 100000)"
check "absent model → table"        '$1.8750'  "$(render claude-opus-4-1 100000)"
check "corrupt line → table"        '$0.2500'  "$(render claude-sonnet-5 100000)"
check "BURNBAR_FRESH_PRICES=0 → table"        '$0.5000'  "$(render claude-opus-5-5 100000 BURNBAR_FRESH_PRICES=0)"
check "fresh cache → no download"   "no"       "$([ -f "$LOCK" ] && echo yes || echo no)"
reset
render claude-opus-5-5 100000 BURNBAR_FORMAT='{ctx}' >/dev/null
check "no {miss} in format → no download" "no" "$([ -f "$LOCK" ] && echo yes || echo no)"

# ── Stale cache ───────────────────────────────────────────────────────────────
reset
printf '%s\n' "$(( NOW - 8 * 86400 ))" "claude-opus-5-5 40 0 0" > "$CACHE"
check "cache older than 7 days → table" '$0.5000' "$(render claude-opus-5-5 100000)"
check "stale cache → download attempt" "yes" "$(wait_for '[ -f "$LOCK" ]' && echo yes)"

# ── Failed download ───────────────────────────────────────────────────────────
reset
printf '%s\n' "$(( NOW - 2 * 86400 ))" "claude-opus-5-5 40 0 0" > "$CACHE"
render claude-opus-5-5 100000 CURL_BODY="$TMP/garbage.json" >/dev/null
wait_for '[ -z "$(ls "$HOM/.cache" | grep -v "^burnbar-prices\(\.lock\)\?$")" ]'
check "garbage keeps the old cache" "claude-opus-5-5 40 0 0" "$(sed -n 2p "$CACHE")"
check "garbage keeps the lock"      "yes" "$([ -f "$LOCK" ] && echo yes)"
check "backoff: no new download"    '$5.0000' "$(render claude-opus-5-5 100000 CURL_BODY="$TMP/api.json")"
sleep 1
check "backoff: cache unchanged"    "claude-opus-5-5 40 0 0" "$(sed -n 2p "$CACHE")"
# Backoff over (lock older than 6 h) → the next tick downloads again.
_old=$(( NOW - 7 * 3600 ))
touch -t "$(date -r "$_old" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$_old" +%Y%m%d%H%M.%S)" "$LOCK"
render claude-opus-5-5 100000 CURL_BODY="$TMP/api.json" >/dev/null
wait_for '[ ! -f "$LOCK" ]'
check "backoff over → download again" "claude-opus-5-5 4 0 0" "$(grep '^claude-opus-5-5 ' "$CACHE")"

# ── No ~/.cache (macOS) ───────────────────────────────────────────────────────
rm -rf "$HOM"; mkdir -p "$HOM"
render claude-opus-5-5 100000 CURL_BODY="$TMP/api.json" >/dev/null
wait_for '[ -f "$CACHE" ] && [ ! -f "$LOCK" ]'
check "no ~/.cache → created, cache written" "claude-opus-5-5 4 0 0" "$(grep '^claude-opus-5-5 ' "$CACHE" 2>/dev/null)"

exit "$fail"
