#!/bin/bash
# Burnbar — Rich statusline for Claude Code
# https://github.com/devnix/burnbar
#
# Configuration via environment variables:
#   BURNBAR_FORMAT      — format string with {tag} placeholders (see README for tags).
#                         {sep}/{wrap} are responsive separators; [[ ... ]] wraps an
#                         optional group that survives iff ≥1 {tag} inside it is non-empty.
#   BURNBAR_BAR_WIDTH   — progress bar width in cells (default: 20)
#   BURNBAR_CACHE_WIDTH — cache bar width in cells (default: 8)
#   BURNBAR_CACHE_TTL   — cache TTL in seconds (default: detected per session, 300 or 3600)
#   BURNBAR_SPARK       — cost sparkline mode: auto|braille|octant|blocks|none
#   BURNBAR_SPARK_WIDTH — sparkline width in cells (default: 8)
#   BURNBAR_MONTHLY_BUDGET — monthly budget in the plan's currency, only used when the
#                            plan reports no limit of its own (0 = no bar)
#   BURNBAR_DAILY_BUDGET   — daily budget in the plan's currency (0 = show spend only, no bar)
#   BURNBAR_WEEKLY_WIDTH   — width of the 7-day (1w) plan-usage meter bar in cells (default: 8)
#   BURNBAR_5H_WIDTH    — width of the 5h plan-usage meter bar in cells (default: 8)
#   BURNBAR_WRAP_SEP    — separator used at {wrap} when line fits (default: "  ")
#   BURNBAR_COLS        — override terminal width for wrap decisions (default: auto via stty)
#   BURNBAR_SEP         — group separator character used at {sep} (default: "│")

# Config dir — respects secondary Claude profiles (CLAUDE_CONFIG_DIR)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Time helpers. bash >= 4.2 has a fork-free strftime builtin (printf %(...)T);
# macOS ships bash 3.2, which falls back to date(1) (-r on BSD, -d on GNU).
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
  _epoch()    { printf -v "$1" '%(%s)T' -1; }       # $1 = var
  _strftime() { printf -v "$1" "%($2)T" "$3"; }     # $1 = var, $2 = format, $3 = epoch
else
  # One date(1) call per tick (2 forks) reads the epoch, the local day and the
  # UTC offset. The tick's day and any %H:%M are then computed by arithmetic;
  # other formats and epochs still fork date(1).
  _ref_epoch=""
  _tick_ref() {
    local _ref_off
    read -r _ref_epoch _ref_day _ref_off <<< "$(date '+%s %Y-%m-%d %z')"
    _ref_secs=$(( 10#${_ref_off:1:2} * 3600 + 10#${_ref_off:3:2} * 60 ))  # %z = +HHMM
    [ "${_ref_off:0:1}" = "-" ] && _ref_secs=$(( -_ref_secs ))
  }
  _epoch() { [ -n "$_ref_epoch" ] || _tick_ref; printf -v "$1" '%s' "$_ref_epoch"; }
  _strftime() {  # $1 = var, $2 = format, $3 = epoch
    [ -n "$_ref_epoch" ] || _tick_ref
    if [ "$2" = '%Y-%m-%d' ] && [ "$3" = "$_ref_epoch" ]; then
      printf -v "$1" '%s' "$_ref_day"
    elif [ "$2" = '%H:%M' ]; then  # uses the offset of now: wrong across a DST change
      local _t=$(( ($3 + _ref_secs) % 86400 ))
      printf -v "$1" '%02d:%02d' $(( _t / 3600 )) $(( _t % 3600 / 60 ))
    else
      printf -v "$1" '%s' "$(date -r "$3" "+$2" 2>/dev/null || date -d "@$3" "+$2")"
    fi
  }
fi

# Format string — resolved up front so data sources can skip work for tags the
# format does not use.
_default_fmt='\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}{wrap}{ctx} {bar} {pct}{sep}{total}{sep}[[cache: {cache}]] {miss}{sep}{delta} {spark}{sep}[[5h: {5h}]]{sep}[[1w: {1w}]]{sep}{monthly}{sep}{daily}'
_fmt="${BURNBAR_FORMAT:-$_default_fmt}"

# ── Billed spend (claude.ai plan-usage endpoint, 5-min cache) ─────────────────
#   Undocumented endpoint (the one /usage reads) — see ADR-0002. Reports the
#   billed spend of the billing period (Enterprise usage, extra-usage credits)
#   and the plan's limit. {daily} is derived from it: the latest reading minus
#   the last reading taken before today's midnight. Only fetched when the format
#   contains {monthly} or {daily}. The 5h / 1w meters come from the JSON
#   rate_limits fields instead.
MONTHLY_BAR_WIDTH=8
DAILY_BAR_WIDTH=8
WEEKLY_BAR_WIDTH="${BURNBAR_WEEKLY_WIDTH:-8}"
PLAN_TTL=300
PLAN_MAX_AGE=3600
# Cache line: used|limit|currency|enabled|epoch|day_baseline|day|daily
PLAN_CACHE="${HOME}/.cache/burnbar-plan-spend-${CONFIG_DIR##*/}"
PLAN_LOCK="${HOME}/.cache/burnbar-plan-spend-${CONFIG_DIR##*/}.lock"

# Print Claude Code's OAuth credentials JSON. Linux: the credentials file. macOS:
# the login Keychain, under the same service/account names Claude Code uses — a
# "-<sha256(config dir)[:8]>" suffix when a non-default config dir is set.
_read_credentials() {
  if [[ "$OSTYPE" == darwin* ]]; then
    local _svc="Claude Code-credentials" _dir="" _acct="${USER:-}"
    if [ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR+x}" ]; then
      _dir="$CLAUDE_SECURESTORAGE_CONFIG_DIR"
    elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
      _dir="$CLAUDE_CONFIG_DIR"
    fi
    [ -n "$_dir" ] && _svc="${_svc}-$(printf '%s' "$_dir" | shasum -a 256 | cut -c1-8)"
    [[ "$_acct" =~ ^[a-zA-Z0-9._-]+$ ]] || _acct=claude-code-user
    security find-generic-password -a "$_acct" -w -s "$_svc" 2>/dev/null
  else
    cat "$CONFIG_DIR/.credentials.json" 2>/dev/null
  fi
}

_update_plan_spend() {
  local _tok _json _used _limit _cur _on _ts _day _hms _h _m _s _sod _base _daily
  local _p_used="" _p_limit _p_cur _p_on _p_epoch=0 _p_base="" _p_day="" _p_daily
  _epoch _ts
  # Read-only use of the token Claude Code keeps fresh. Never refresh it here:
  # a refresh rotates the refresh token and can log Claude Code out. On a
  # failure (401, 429, network, expired token) write nothing and keep the lock:
  # the lock's 5-min age check in _spawn_refresh is the retry backoff.
  _tok=$(_read_credentials | jq -r \
           '.claudeAiOauth | select((.expiresAt // 0) > now * 1000) | .accessToken // empty' 2>/dev/null)
  [ -n "$_tok" ] || return
  # Header via stdin, not argv: argv is world-readable in /proc/*/cmdline.
  _json=$(printf 'Authorization: Bearer %s\n' "$_tok" | curl -fsS -m 10 -H @- \
            -H 'anthropic-beta: oauth-2025-04-20' \
            https://api.anthropic.com/api/oauth/usage 2>/dev/null)
  _tok=""
  [ -n "$_json" ] || return
  read -r _used _limit _cur _on < <(printf '%s' "$_json" | jq -r '
    def amt(m; e): (m // 0) / pow(10; e // 2);
    if (.spend.used.amount_minor | type) == "number" then
      [ amt(.spend.used.amount_minor; .spend.used.exponent),
        amt(.spend.limit.amount_minor; .spend.limit.exponent),
        (.spend.used.currency // "USD"), (if .spend.enabled then 1 else 0 end) ]
    elif (.extra_usage.used_credits | type) == "number" then
      [ amt(.extra_usage.used_credits; .extra_usage.decimal_places),
        amt(.extra_usage.monthly_limit; .extra_usage.decimal_places),
        (.extra_usage.currency // "USD"), (if .extra_usage.is_enabled then 1 else 0 end) ]
    else empty end | map(tostring) | join(" ")' 2>/dev/null)
  # Persist guard: only overwrite the cache with a fully parsed reading.
  case "$_used$_limit" in ''|*[!0-9.]*) return ;; esac
  case "$_cur" in [A-Z][A-Z][A-Z]) ;; *) _cur=USD ;; esac

  # Day baseline. Same day → keep it. New day → the previous reading, if it was
  # taken yesterday (the spend between it and midnight lands on today); with no
  # recent reading, today starts at the current amount.
  [ -f "$PLAN_CACHE" ] && IFS='|' read -r _p_used _p_limit _p_cur _p_on _p_epoch _p_base _p_day _p_daily \
    < "$PLAN_CACHE"
  case "$_p_epoch" in ''|*[!0-9]*) _p_epoch=0 ;; esac
  _strftime _day '%Y-%m-%d' "$_ts"
  if [ "$_p_day" = "$_day" ] && [ -n "$_p_base" ]; then
    _base="$_p_base"
  else
    _strftime _hms '%H %M %S' "$_ts"; read -r _h _m _s <<< "$_hms"
    _sod=$(( _ts - 10#$_h * 3600 - 10#$_m * 60 - 10#$_s ))
    if [ -n "$_p_used" ] && [ "$_p_epoch" -ge $(( _sod - 86400 )) ]; then
      _base="$_p_used"
    else
      _base="$_used"
    fi
  fi
  # The amount went down → a new billing period started: count today from zero.
  read -r _base _daily < <(LC_NUMERIC=C awk -v u="$_used" -v b="$_base" \
    'BEGIN { if (u + 0 < b + 0) b = 0; printf "%.2f %.2f\n", b, u - b }')

  LC_NUMERIC=C printf '%.2f|%.2f|%s|%d|%d|%s|%s|%s\n' \
    "$_used" "$_limit" "$_cur" "${_on:-0}" "$_ts" "$_base" "$_day" "$_daily" \
    > "$PLAN_CACHE" && rm -f "${PLAN_LOCK}"
}

# Start a background refresh unless another one holds a fresh (<5 min) lock.
# Redirect the job's stdout/stderr so it does not keep the statusline's stdout
# pipe open: Claude Code reads stdout until EOF, which would otherwise block
# until the (slow) refresh finishes.
_spawn_refresh() {  # $1 = refresh function, $2 = lock file
  local _lock_mtime
  if [ -f "$2" ]; then
    # GNU stat -c, BSD/macOS stat -f. An unreadable mtime must not disable the
    # lock: that would turn a failing refresh into one request per tick.
    _lock_mtime=$(stat -c %Y "$2" 2>/dev/null || stat -f %m "$2" 2>/dev/null)
    case "$_lock_mtime" in ''|*[!0-9]*) return ;; esac
    # shellcheck disable=SC2154  # _epoch assigns it (printf -v)
    [ "$(( _spend_now - _lock_mtime ))" -lt 300 ] && return
  fi
  # No lock, no spawn: without it nothing stops a new job every tick. macOS
  # often has no ~/.cache.
  [ -d "${2%/*}" ] || mkdir -p "${2%/*}" 2>/dev/null
  touch "$2" 2>/dev/null || return
  "$1" >/dev/null 2>&1 &
}

_epoch _spend_now
plan_used="" plan_limit="" plan_cur="" _plan_epoch=0 plan_day="" plan_daily=""
# No credentials (API-key auth) → never fetch. macOS keeps them in the Keychain.
if [[ "$_fmt" == *'{monthly}'* || "$_fmt" == *'{daily}'* ]] \
   && { [[ "$OSTYPE" == darwin* ]] || [ -f "$CONFIG_DIR/.credentials.json" ]; }; then
  [ -f "${PLAN_CACHE}" ] && IFS='|' read -r plan_used plan_limit plan_cur _ _plan_epoch \
    _ plan_day plan_daily < "${PLAN_CACHE}"
  case "$_plan_epoch" in ''|*[!0-9]*) _plan_epoch=0 ;; esac
  [ "$(( _spend_now - _plan_epoch ))" -gt "$PLAN_TTL" ] && _spawn_refresh _update_plan_spend "$PLAN_LOCK"
fi

# A reading older than PLAN_MAX_AGE is not shown. The plan's limit is the
# monthly budget; BURNBAR_MONTHLY_BUDGET only applies when the plan has none.
monthly_amt="" daily_amt="" monthly_budget="${BURNBAR_MONTHLY_BUDGET:-0}" spend_sym='$'
if [ -n "$plan_used" ] && [ "$(( _spend_now - _plan_epoch ))" -le "$PLAN_MAX_AGE" ]; then
  monthly_amt="$plan_used"
  [ "$plan_limit" != "0.00" ] && monthly_budget="${plan_limit%.00}"
  _strftime _today '%Y-%m-%d' "$_spend_now"
  # Past midnight but not refreshed yet → nothing spent today so far.
  # shellcheck disable=SC2154  # _strftime assigns it (printf -v)
  if [ "$plan_day" = "$_today" ] && [ -n "$plan_daily" ]; then daily_amt="$plan_daily"; else daily_amt="0.00"; fi
  case "$plan_cur" in
    USD) spend_sym='$' ;; EUR) spend_sym='€' ;; GBP) spend_sym='£' ;;
    *)   spend_sym="${plan_cur} " ;;
  esac
fi

# ── Parse input (single jq call) ─────────────────────────────────────────────
input=$(cat)
# The eval below assigns these; ShellCheck sees no other assignment (SC2154).
declare cwd model_id used_pct input_toks cw_toks cr_toks total_cost_raw
jq_out=$(jq -r '
  "cwd=" + ((.cwd // "") | @sh),
  "_model=" + ((.model.display_name // "") | @sh),
  "model_id=" + ((.model.id // "" | ascii_downcase) | @sh),
  "used_pct=" + ((.context_window.used_percentage // 0) | @sh),
  "input_toks=" + ((if .context_window.current_usage then .context_window.current_usage.input_tokens // 0 else 0 end) | @sh),
  "cw_toks=" + ((if .context_window.current_usage then .context_window.current_usage.cache_creation_input_tokens // 0 else 0 end) | @sh),
  "cr_toks=" + ((if .context_window.current_usage then .context_window.current_usage.cache_read_input_tokens // 0 else 0 end) | @sh),
  "total_cost_raw=" + ((.cost.total_cost_usd // 0) | @sh),
  "session_id=" + ((.session_id // "") | @sh),
  "current_effort=" + ((.effort.level // "") | @sh),
  "fh_pct="   + ((.rate_limits.five_hour.used_percentage // "") | @sh),
  "fh_reset=" + ((.rate_limits.five_hour.resets_at       // "") | @sh),
  "sd_pct="   + ((.rate_limits.seven_day.used_percentage // "") | @sh),
  "sd_reset=" + ((.rate_limits.seven_day.resets_at       // "") | @sh)
' <<< "$input") && eval "$jq_out"

# ── Pricing + model family ────────────────────────────────────────────────────
#   Base input price ($/MTok) — the cache-miss cost is a multiple of it. The
#   price changes per version, not per family: the specific globs go first. An
#   unlisted version of a known family gets the newest price of that family.
#   price_lc/price_lc_in: above price_lc tokens of context, the input price is
#   price_lc_in (Haiku 5.5; 0 = no long-context tier).
price_lc=0 price_lc_in=0 model_known=1
case "${model_id%%\[*}" in  # without a "[1m]" suffix
  *fable*|*mythos*)                    price_in=10;   model_family="fable" ;;
  *opus-4-1*|*opus-4-2025*|*3-opus*)   price_in=15;   model_family="opus" ;;
  *opus-4-*|*opus-5-2*|*opus-5)        price_in=5;    model_family="opus" ;;
  *opus*)                              price_in=4;    model_family="opus" ;;
  *sonnet-4*|*3-7-sonnet*|*3-5-sonnet*) price_in=3;   model_family="sonnet" ;;
  *sonnet*)                            price_in=2;    model_family="sonnet" ;;
  *haiku-4*)                           price_in=1;    model_family="haiku" ;;
  *3-5-haiku*)                         price_in=0.80; model_family="haiku" ;;
  *3-haiku*)                           price_in=0.25; model_family="haiku" ;;
  *haiku*)                             price_in=0.10; model_family="haiku" price_lc=100000 price_lc_in=0.50 ;;
  *)                                   price_in=0;    model_family="unknown" model_known=0 ;;
esac

# ── Header ────────────────────────────────────────────────────────────────────
_user="${USER:-$(whoami)}"
_host="${HOSTNAME%%.*}"
_cwd="$cwd"

# ── Cache timer: read timestamp before awk ────────────────────────────────────
BAR_WIDTH="${BURNBAR_BAR_WIDTH:-20}"
CACHE_BAR_WIDTH="${BURNBAR_CACHE_WIDTH:-8}"
FH_BAR_WIDTH="${BURNBAR_5H_WIDTH:-8}"
UNFILLED_BG="47"

cache_key="${session_id:0:8}"
# Cache TTL: BURNBAR_CACHE_TTL, else the one the Stop hook read from the
# transcript (300 or 3600), else 300 (the API default, until the first turn).
CACHE_TTL="${BURNBAR_CACHE_TTL:-}"
case "$CACHE_TTL" in
  ''|0|*[!0-9]*)
    CACHE_TTL=""
    [ -f "$CONFIG_DIR/.cache-ttl-$cache_key" ] && read -r CACHE_TTL < "$CONFIG_DIR/.cache-ttl-$cache_key"
    case "$CACHE_TTL" in 300|3600) ;; *) CACHE_TTL=300 ;; esac ;;
esac
# Cache-write price multiplier of the base input price: 2x for 1h, 1.25x for 5m
if [ "$CACHE_TTL" -gt 300 ]; then cache_wmul=2; else cache_wmul=1.25; fi
ts_file="$CONFIG_DIR/.cache-ts-$cache_key"
remaining=0
has_cache=0
if [ -f "$ts_file" ]; then
  read -r last < "$ts_file" 2>/dev/null
  if ! [ "$last" -gt 0 ] 2>/dev/null; then last=0; fi
  if [ "$last" -gt 0 ] 2>/dev/null; then
    elapsed=$((_spend_now - last))
    remaining=$((CACHE_TTL - elapsed))
    [ "$remaining" -lt 0 ] && remaining=0
    has_cache=1
  fi
fi

# ── Terminal family (shared by notification channel and sparkline mode) ──────
case "${TERM_PROGRAM:-}" in
  ghostty) TERM_FAMILY="ghostty" ;;
  iTerm*)  TERM_FAMILY="iterm" ;;
  WezTerm) TERM_FAMILY="wezterm" ;;
  *) [ -n "${KITTY_WINDOW_ID:-}" ] && TERM_FAMILY="kitty" || TERM_FAMILY="other" ;;
esac

# ── Cost sparkline: read per-turn state before awk ────────────────────────────
#   .turn-ts-<key>  — written by the Stop hook (turn boundary, opaque marker)
#   .cost-hist-<key> — 3 lines: marker, cost baseline, space-separated deltas
SPARK_MODE="${BURNBAR_SPARK:-auto}"
SPARK_WIDTH="${BURNBAR_SPARK_WIDTH:-8}"
case "$SPARK_WIDTH" in ''|0|*[!0-9]*) SPARK_WIDTH=8 ;; esac
if [ "$SPARK_MODE" = "auto" ]; then
  # Octants (Unicode 16) render natively in Ghostty and Kitty; braille elsewhere
  case "$TERM_FAMILY" in
    ghostty|kitty) SPARK_MODE="octant" ;;
    *)             SPARK_MODE="braille" ;;
  esac
fi
spark_new=0 spark_record=0 spark_init=0 spark_base="" spark_hist="" spark_marker="" turn_ts=""
spark_window=0 spark_keep=0 spark_lmax=8
if [ "$SPARK_MODE" != "none" ] && [ -n "$session_id" ]; then
  # Render window: blocks fits 1 turn per cell (levels 0-8), braille/octant
  # fit 2 (levels 0-4 per column). The persisted history keeps at least 32
  # turns so narrowing the display mode/width never destroys data.
  if [ "$SPARK_MODE" = "blocks" ]; then
    spark_window=$SPARK_WIDTH
  else
    spark_window=$((SPARK_WIDTH * 2)) spark_lmax=4
  fi
  spark_keep=$((spark_window > 32 ? spark_window : 32))
  turn_file="$CONFIG_DIR/.turn-ts-$cache_key"
  hist_file="$CONFIG_DIR/.cost-hist-$cache_key"
  [ -f "$turn_file" ] && read -r turn_ts < "$turn_file" 2>/dev/null
  if [ -f "$hist_file" ]; then
    { read -r spark_marker; read -r spark_base; read -r spark_hist; } < "$hist_file" 2>/dev/null
  fi
  # A corrupt/truncated baseline would make the next delta swallow the whole
  # session cost — treat it as a re-init (baseline rewritten, no delta recorded).
  # eE+- are allowed: jq renders tiny costs in scientific notation (e.g. 7E-7),
  # which awk parses fine — rejecting them would needlessly wipe a valid baseline.
  case "$spark_base" in ''|*[!0-9.eE+-]*) spark_base="" ;; esac
  if [ -n "$turn_ts" ] && [ "$turn_ts" != "$spark_marker" ]; then
    spark_new=1
    # Any baseline (incl. the one captured at tracking start) lets even the
    # FIRST turn record total - baseline; missing/corrupt falls back to re-init.
    [ -n "$spark_base" ] && spark_record=1
  elif [ -z "$spark_base" ]; then
    # No turn boundary and no baseline yet: flag tracking start so the persist
    # block seeds the baseline before the first turn (else the first turn's
    # delta is lost). On a resumed session this captures the accumulated total,
    # so the first post-resume turn measures only its own cost.
    spark_init=1
  fi
fi

# ── Pty discovery (shared by notification and width detection) ────────────────
#   Walks /proc tree to find the parent pty. Sets caller's _tty_dev via bash
#   dynamic scoping — declare 'local _tty_dev=""' in the calling function.
_find_tty() {
  local _pid=$PPID _fd _n
  while [ "${_pid:-0}" -gt 1 ] 2>/dev/null; do
    for _n in 1 2 0; do
      _fd=$(readlink "/proc/$_pid/fd/$_n" 2>/dev/null) || continue
      case "$_fd" in /dev/pts/*|/dev/tty*) _tty_dev="$_fd"; return ;; esac
    done
    _pid=$(awk '{sub(/.*\) /, ""); print $2}' "/proc/$_pid/stat" 2>/dev/null) || break
  done
}

# ── Cache half-time notification ──────────────────────────────────────────────
#   Fires once per cache period when remaining crosses 50%.
#   BURNBAR_NOTIFY: auto|osc9|osc99|osc777|bell|none
_maybe_notify() {
  [ "$has_cache" = 1 ] && [ "$remaining" -gt 0 ] && [ "$remaining" -le $((CACHE_TTL / 2)) ] || return 0
  local _notif_file="$CONFIG_DIR/.cache-notif-$cache_key"
  if [ -f "$_notif_file" ]; then
    local _notif_ts; read -r _notif_ts < "$_notif_file" 2>/dev/null
    [ "$_notif_ts" = "$last" ] && return 0
  fi
  local _tty_dev=""
  _find_tty
  [ -n "$_tty_dev" ] || return 0
  local _notif_msg _nm _sent=0
  printf -v _notif_msg 'Burnbar: cache 50%% — %d:%02d remaining' "$((remaining / 60))" "$((remaining % 60))"
  _nm="${BURNBAR_NOTIFY:-auto}"
  if [ "$_nm" = "auto" ]; then
    local _pref
    _pref=$(jq -r '.preferredNotifChannel // empty' "$CONFIG_DIR/settings.json" 2>/dev/null)
    if [ "$_pref" = "terminal_bell" ]; then
      _nm="bell"
    else
      case "$TERM_FAMILY" in
        osc9)  _nm="osc9" ;;
        kitty) _nm="osc99" ;;
        *)     _nm="osc777" ;;
      esac
    fi
  fi
  case "$_nm" in
    osc9)   printf '\033]9;%s\a' "$_notif_msg" > "$_tty_dev" 2>/dev/null && _sent=1 ;;
    osc99)  printf '\033]99;i=burnbar:d=0;%s\033\\' "$_notif_msg" > "$_tty_dev" 2>/dev/null && _sent=1 ;;
    osc777) printf '\033]777;notify;Burnbar;%s\a' "$_notif_msg" > "$_tty_dev" 2>/dev/null && _sent=1 ;;
    bell)   printf '\a' > "$_tty_dev" 2>/dev/null && _sent=1 ;;
    none)   _sent=1 ;;
  esac
  [ "$_sent" = 1 ] && printf '%s\n' "$last" > "$_notif_file"
}
_maybe_notify

# ── Terminal column detection (for responsive wrap) ───────────────────────────
#   Sets global _term_cols. Always reads from the pty (accurate on every resize).
#   Override with BURNBAR_COLS=N to bypass pty detection.
_detect_cols() {
  _term_cols=80  # conservative fallback when pty walk fails — wraps rather than overflows
  [ "${BURNBAR_COLS:-0}" -gt 0 ] 2>/dev/null && { _term_cols="$BURNBAR_COLS"; return; }
  local _tty_dev="" _sz="" _cols=""
  _find_tty
  [ -n "$_tty_dev" ] || return
  _sz=$(stty size < "$_tty_dev" 2>/dev/null)
  _cols="${_sz##* }"
  [ "${_cols:-0}" -gt 0 ] 2>/dev/null && _term_cols="$_cols"
}


# ── All numeric computation (single awk call) ────────────────────────────────
read -r used_pct_int filled_full partial_idx ctx_fmt miss_cost total_cost \
  cache_filled_full cache_partial_idx spark_levels last_delta \
  spend_pct monthly_filled monthly_partial \
  daily_pct daily_filled daily_partial \
  fh_filled fh_partial sd_filled sd_partial \
  spark_newhist <<< "$(
  LC_NUMERIC=C awk -v pct="$used_pct" -v bw="$BAR_WIDTH" \
      -v it="$input_toks" -v cwt="$cw_toks" -v crt="$cr_toks" \
      -v pin="$price_in" -v plc="$price_lc" -v plcin="$price_lc_in" -v wmul="$cache_wmul" \
      -v traw="$total_cost_raw" \
      -v rem="$remaining" -v ttl="$CACHE_TTL" -v cbw="$CACHE_BAR_WIDTH" \
      -v srec="$spark_record" -v sb="$spark_base" -v shist="$spark_hist" \
      -v smaxn="$spark_window" -v skeep="$spark_keep" -v lmax="$spark_lmax" \
      -v sraw="${monthly_amt:-0}" -v sbudget="${monthly_budget:-0}" -v mbw="$MONTHLY_BAR_WIDTH" \
      -v draw="${daily_amt:-0}" -v dbudget="${BURNBAR_DAILY_BUDGET:-0}"  -v dbw="$DAILY_BAR_WIDTH" \
      -v fhpct="${fh_pct:-0}" -v fhbw="$FH_BAR_WIDTH" \
      -v sdpct="${sd_pct:-0}" -v sdbw="$WEEKLY_BAR_WIDTH" \
  'BEGIN {
    pct_int = int(pct + 0.5)

    f = pct / 100 * bw
    if (f > bw) f = bw; if (f < 0) f = 0
    ff = int(f)
    pi = int((f - ff) * 8)
    if (pi > 7) pi = 7; if (pi < 0) pi = 0

    ctx = it + cwt + crt
    if (ctx >= 1000) cfmt = sprintf("%.1fk", ctx / 1000)
    else cfmt = sprintf("%d", ctx)

    # Cache miss: the whole context is written to the cache again, at the
    # cache-write rate of the session TTL
    if (plc > 0 && ctx > plc) pin = plcin
    cost = ctx * pin * wmul / 1000000
    cost = int(cost * 10000 + 0.5) / 10000

    tc = int(traw * 10000 + 0.5) / 10000

    if (ttl > 0 && rem > 0) {
      cf = rem / ttl * cbw
      if (cf > cbw) cf = cbw; if (cf < 0) cf = 0
      cff = int(cf)
      cpi = int((cf - cff) * 8)
      if (cpi > 7) cpi = 7; if (cpi < 0) cpi = 0
    } else { cff = 0; cpi = 0 }

    # Sparkline: append this turn delta, render last smaxn turns quantized to
    # the mode-native lmax levels (8 for blocks, 4 per column for braille/octant)
    if (srec) {
      d = traw - sb; if (d < 0) d = 0
      shist = (shist == "") ? sprintf("%.4f", d) : shist " " sprintf("%.4f", d)
    }
    n = split(shist, sh, " ")
    si = (n > smaxn) ? n - smaxn + 1 : 1
    smax = 0
    for (i = si; i <= n; i++) if (sh[i] + 0 > smax) smax = sh[i] + 0
    slv = ""
    for (i = si; i <= n; i++) {
      if (sh[i] + 0 <= 0) l = 0
      else {
        l = int(sh[i] / smax * lmax + 0.5)
        if (l < 1) l = 1; if (l > lmax) l = lmax
      }
      slv = slv l
    }
    if (slv == "") slv = "-"
    # Persisted history is only consumed on turn boundaries; keep skeep turns
    # (>= any render window) so display-mode changes never destroy data
    snew = ""
    if (srec) {
      ki = (n > skeep) ? n - skeep + 1 : 1
      for (i = ki; i <= n; i++) snew = (snew == "") ? sh[i] : snew " " sh[i]
    }
    ld = (n > 0) ? sprintf("%.4f", sh[n] + 0) : "0.0000"

    spct = (sbudget > 0) ? sraw / sbudget * 100 : 0
    mf = spct / 100 * mbw
    if (mf > mbw) mf = mbw; if (mf < 0) mf = 0
    mff = int(mf)
    mpi = int((mf - mff) * 8)
    if (mpi > 7) mpi = 7; if (mpi < 0) mpi = 0

    dpct = (dbudget > 0) ? draw / dbudget * 100 : 0
    df = dpct / 100 * dbw
    if (df > dbw) df = dbw; if (df < 0) df = 0
    dff = int(df)
    dpi = int((df - dff) * 8)
    if (dpi > 7) dpi = 7; if (dpi < 0) dpi = 0

    # 5h / 1w plan-usage meters: used_percentage (0-100) drives a filling bar
    fhf = fhpct / 100 * fhbw
    if (fhf > fhbw) fhf = fhbw; if (fhf < 0) fhf = 0
    fhff = int(fhf); fhpi = int((fhf - fhff) * 8)
    if (fhpi > 7) fhpi = 7; if (fhpi < 0) fhpi = 0

    sdf = sdpct / 100 * sdbw
    if (sdf > sdbw) sdf = sdbw; if (sdf < 0) sdf = 0
    sdff = int(sdf); sdpi = int((sdf - sdff) * 8)
    if (sdpi > 7) sdpi = 7; if (sdpi < 0) sdpi = 0

    printf "%d %d %d %s %.4f %.4f %d %d %s %s %.1f %d %d %.1f %d %d %d %d %d %d %s", pct_int, ff, pi, cfmt, cost, tc, cff, cpi, slv, ld, spct, mff, mpi, dpct, dff, dpi, fhff, fhpi, sdff, sdpi, snew
  }'
)"

# ── Cost sparkline: persist state (sole writer of the history file) ───────────
# A recorded turn must produce deltas — the guard keeps a failed awk/jq tick
# from wiping the accumulated history (same class as the notification sentinel)
if [ "$spark_new" = 1 ]; then
  if [ "$spark_record" = 0 ] || [ -n "$spark_newhist" ]; then
    # On re-init (record=0) keep the previously stored deltas — only the
    # baseline was missing/corrupt, the history itself is still valid
    printf '%s\n%s\n%s\n' "$turn_ts" "$total_cost_raw" "${spark_newhist:-$spark_hist}" > "$hist_file"
  fi
elif [ "$spark_init" = 1 ]; then
  # Tracking start: seed the baseline (empty marker, untouched history) once,
  # before the first turn boundary
  printf '%s\n%s\n%s\n' "$spark_marker" "$total_cost_raw" "$spark_hist" > "$hist_file"
fi

# ── Color for usage level ─────────────────────────────────────────────────────
if [ "$used_pct_int" -ge 80 ] 2>/dev/null; then
  level_bold="01;31"
elif [ "$used_pct_int" -ge 50 ] 2>/dev/null; then
  level_bold="01;33"
else
  level_bold="01;32"
fi

# ── Bar rendering (shared by context and cache bars, zero forks) ──────────────
_partials=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")
_render_bar() {
  local _w=$1 _filled=$2 _partial=$3 _fg=$4 _bg=$5 _threshold=$6
  local _i=0 _cbg _cfg
  _bar_out=""
  while [ "$_i" -lt "$_w" ]; do
    if [ "$_i" -lt "$_filled" ]; then
      if [ "$_threshold" = 1 ]; then
        if [ $((2 * _i + 1)) -lt "$_w" ]; then _cbg=42
        elif [ $((10 * _i + 5)) -lt $((_w * 8)) ]; then _cbg=43
        else _cbg=41; fi
      else _cbg=$_bg; fi
      _bar_out="${_bar_out}\033[${_cbg}m \033[0m"
    elif [ "$_i" -eq "$_filled" ] && [ "$_filled" -lt "$_w" ]; then
      if [ "$_threshold" = 1 ]; then
        if [ $((2 * _i + 1)) -lt "$_w" ]; then _cfg=32
        elif [ $((10 * _i + 5)) -lt $((_w * 8)) ]; then _cfg=33
        else _cfg=31; fi
      else _cfg=$_fg; fi
      if [ "$_partial" -gt 0 ]; then
        _bar_out="${_bar_out}\033[${_cfg};${UNFILLED_BG}m${_partials[$_partial]}\033[0m"
      else
        _bar_out="${_bar_out}\033[${UNFILLED_BG}m \033[0m"
      fi
    else
      _bar_out="${_bar_out}\033[${UNFILLED_BG}m \033[0m"
    fi
    _i=$((_i + 1))
  done
}

_render_bar "$BAR_WIDTH" "$filled_full" "$partial_idx" "" "" 1
_bar="$_bar_out"

# ── Computed fields ───────────────────────────────────────────────────────────
_pct="${used_pct_int}%"
_ctx="ctx:\033[${level_bold}m${ctx_fmt}\033[00m"
# {miss}: cost of the next message on a cache miss. Red when the cache has
# expired: the next message pays it. {next} is its former name (an alias).
if [ "$model_known" = 1 ]; then
  if [ "$has_cache" = 1 ] && [ "$remaining" -eq 0 ]; then _miss_c="01;31"; else _miss_c="01;33"; fi
  _miss="miss:\033[${_miss_c}m\$${miss_cost}\033[00m"
else
  _miss="miss:\033[01;33m⚠ unknown model: ${model_id}\033[00m"
fi
_next="$_miss"
_total="total:\033[01;31m\$${total_cost}\033[00m"
_delta="delta:\033[01;36m\$${last_delta}\033[00m"

# ── Cache timer rendering ─────────────────────────────────────────────────────
_cache=""
if [ "$has_cache" = 1 ]; then
  cache_alert=""
  if [ -n "$session_id" ]; then
    meta_file="$CONFIG_DIR/.cache-meta-$cache_key"

    if [ -f "$meta_file" ]; then
      IFS='|' read -r meta_ts meta_model meta_effort < "$meta_file"
    else
      meta_ts="" meta_model="" meta_effort=""
    fi

    if [ -z "$meta_model" ] || [ "$meta_ts" != "$last" ]; then
      printf '%s|%s|%s\n' "$last" "$model_family" "$current_effort" > "$meta_file"
    else
      { [ "$meta_model" != "$model_family" ]; } && cache_alert="model"
      { [ -z "$cache_alert" ] && [ -n "$current_effort" ] && [ "$meta_effort" != "$current_effort" ]; } && cache_alert="effort"
    fi
  fi

  # Green above 40% of the TTL, yellow above 20% (2:00 / 1:00 on a 5m cache)
  if [ $((remaining * 5)) -gt $((CACHE_TTL * 2)) ]; then
    cache_fg="32"; cache_bg="42"
  elif [ $((remaining * 5)) -gt "$CACHE_TTL" ]; then
    cache_fg="33"; cache_bg="43"
  else
    cache_fg="31"; cache_bg="41"
  fi

  printf -v countdown '%02d:%02d' $((remaining / 60)) $((remaining % 60))

  _render_bar "$CACHE_BAR_WIDTH" "$cache_filled_full" "$cache_partial_idx" "$cache_fg" "$cache_bg" 0

  if [ -n "$cache_alert" ]; then
    _cache="${_bar_out} \033[${cache_fg}m${countdown}\033[0m \033[01;33m⚠ ${cache_alert}\033[0m"
  else
    _cache="${_bar_out} \033[${cache_fg}m${countdown}\033[0m"
  fi
else
  _render_bar "$CACHE_BAR_WIDTH" 0 0 "" "" 0
  _cache="${_bar_out} \033[37m--:--\033[0m"
fi

# ── Cost sparkline rendering ──────────────────────────────────────────────────
#   Per-turn cost deltas as a sparkline. 2 turns per cell (braille/octant),
#   1 turn per cell (blocks). awk already trimmed the levels to the window.
_spark=""
if [ "$SPARK_MODE" != "none" ]; then
  _s="" _spark_cells=0 _lv="$spark_levels"
  if [ -n "$_lv" ] && [ "$_lv" != "-" ]; then
    _i=0
    if [ "$SPARK_MODE" = "blocks" ]; then
      _tbl=(" " "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
      while [ "$_i" -lt "${#_lv}" ]; do
        _s="${_s}${_tbl[${_lv:_i:1}]}"
        _i=$((_i + 1))
      done
      _spark_cells=${#_lv}
    else
      # Lookup tables: index = left_level * 5 + right_level (levels 0-4 per column)
      if [ "$SPARK_MODE" = "octant" ]; then
        _tbl=(" " "𜺠" "▗" "𜶖" "▐" "𜺣" "▂" "𜷋" "𜷓" "𜷕" "▖" "𜶻" "▄" "𜷡" "▟" "𜵈" "𜶿" "𜷞" "▆" "𜷥" "▌" "𜷀" "▙" "𜷤" "█")
      else
        _tbl=("⠀" "⢀" "⢠" "⢰" "⢸" "⡀" "⣀" "⣠" "⣰" "⣸" "⡄" "⣄" "⣤" "⣴" "⣼" "⡆" "⣆" "⣦" "⣶" "⣾" "⡇" "⣇" "⣧" "⣷" "⣿")
      fi
      [ $((${#_lv} % 2)) -eq 1 ] && _lv="0$_lv"
      while [ "$_i" -lt "${#_lv}" ]; do
        # Digits are already 0-4 per column (awk quantizes to lmax per mode)
        _s="${_s}${_tbl[${_lv:_i:1}*5+${_lv:_i+1:1}]}"
        _i=$((_i + 2))
      done
      _spark_cells=$((${#_lv} / 2))
    fi
  fi
  _pad=$((SPARK_WIDTH - _spark_cells))
  [ "$_pad" -lt 0 ] && _pad=0
  _spark="" _i=0
  while [ "$_i" -lt "$_pad" ]; do
    _spark="${_spark}\033[${UNFILLED_BG}m \033[0m"
    _i=$((_i + 1))
  done
  [ -n "$_s" ] && _spark="${_spark}\033[36;${UNFILLED_BG}m${_s}\033[0m"
fi

# ── Monthly + daily spend rendering ──────────────────────────────────────────
_monthly="" _daily=""
if [ -n "$monthly_amt" ]; then
  _mp="${spend_pct%%.*}"
  if [ "${_mp:-0}" -ge 90 ] 2>/dev/null; then _mbg=41; _mfg=31
  elif [ "${_mp:-0}" -ge 70 ] 2>/dev/null; then _mbg=43; _mfg=33
  else _mbg=42; _mfg=32; fi
  if [ "${monthly_budget:-0}" != "0" ]; then
    _render_bar "$MONTHLY_BAR_WIDTH" "$monthly_filled" "$monthly_partial" "$_mfg" "$_mbg" 0
    _monthly="mo:\033[${_mfg}m${spend_sym}${monthly_amt}/${spend_sym}${monthly_budget}\033[0m ${_bar_out} \033[${_mfg}m${spend_pct}%\033[0m"
  else
    _monthly="mo:\033[01;36m${spend_sym}${monthly_amt}\033[0m"
  fi
fi
if [ -n "$daily_amt" ]; then
  _dp="${daily_pct%%.*}"
  if [ "${_dp:-0}" -ge 90 ] 2>/dev/null; then _dbg=41; _dfg=31
  elif [ "${_dp:-0}" -ge 70 ] 2>/dev/null; then _dbg=43; _dfg=33
  else _dbg=42; _dfg=32; fi
  if [ "${BURNBAR_DAILY_BUDGET:-0}" != "0" ]; then
    _render_bar "$DAILY_BAR_WIDTH" "$daily_filled" "$daily_partial" "$_dfg" "$_dbg" 0
    _daily="day:\033[${_dfg}m${spend_sym}${daily_amt}/${spend_sym}${BURNBAR_DAILY_BUDGET}\033[0m ${_bar_out} \033[${_dfg}m${daily_pct}%\033[0m"
  else
    _daily="day:\033[01;36m${spend_sym}${daily_amt}\033[0m"
  fi
fi

# ── 5h + 1w plan-usage meters (from JSON rate_limits) ─────────────────────────
#   Filling bar = % of the plan window consumed (green → yellow → red), plus a
#   live countdown to reset and the absolute reset clock. Absent rate_limits
#   (non-subscriber, or before the first API response) → empty string, so the
#   [[ ]] group around the tag disappears entirely (no "--" placeholder).
_5h="" _1w=""
_now="$_spend_now"
if [ -n "$fh_pct" ]; then
  _fhp="${fh_pct%%.*}"
  if [ "${_fhp:-0}" -ge 90 ] 2>/dev/null; then _fh_bg=41; _fh_fg=31
  elif [ "${_fhp:-0}" -ge 70 ] 2>/dev/null; then _fh_bg=43; _fh_fg=33
  else _fh_bg=42; _fh_fg=32; fi
  _render_bar "$FH_BAR_WIDTH" "$fh_filled" "$fh_partial" "$_fh_fg" "$_fh_bg" 0
  _5h="${_bar_out} \033[${_fh_fg}m${_fhp:-0}%\033[0m"
  if [ -n "$fh_reset" ] && [ "${fh_reset%%.*}" -gt 0 ] 2>/dev/null; then
    _strftime _fh_clock '%H:%M' "${fh_reset%%.*}"
    # shellcheck disable=SC2154  # _strftime assigns it (printf -v)
    _5h="${_5h} ↺\033[${_fh_fg}m${_fh_clock}\033[0m"
  fi
fi
if [ -n "$sd_pct" ]; then
  _sdp="${sd_pct%%.*}"
  if [ "${_sdp:-0}" -ge 90 ] 2>/dev/null; then _sd_bg=41; _sd_fg=31
  elif [ "${_sdp:-0}" -ge 70 ] 2>/dev/null; then _sd_bg=43; _sd_fg=33
  else _sd_bg=42; _sd_fg=32; fi
  _render_bar "$WEEKLY_BAR_WIDTH" "$sd_filled" "$sd_partial" "$_sd_fg" "$_sd_bg" 0
  _1w="${_bar_out} \033[${_sd_fg}m${_sdp:-0}%\033[0m"
  if [ -n "$sd_reset" ] && [ "${sd_reset%%.*}" -gt 0 ] 2>/dev/null; then
    _sd_secs=$(( ${sd_reset%%.*} - _now )); [ "$_sd_secs" -lt 0 ] && _sd_secs=0
    # The 7-day window can span days; fall back to H:MM under 24h.
    if [ "$_sd_secs" -ge 86400 ]; then
      printf -v _sd_countdown '%dd %dh' $(( _sd_secs / 86400 )) $(( (_sd_secs % 86400) / 3600 ))
    else
      printf -v _sd_countdown '%d:%02d' $(( _sd_secs / 3600 )) $(( (_sd_secs % 3600) / 60 ))
    fi
    _1w="${_1w} \033[${_sd_fg}m${_sd_countdown}\033[0m"
    if [ "$_sd_secs" -lt 86400 ]; then
      _strftime _sd_clock '%H:%M' "${sd_reset%%.*}"
      # shellcheck disable=SC2154  # _strftime assigns it (printf -v)
      _1w="${_1w} ↺\033[${_sd_fg}m${_sd_clock}\033[0m"
    fi
  fi
fi

# ── Format string and substitution engine ─────────────────────────────────────
_user="${_user//\\/\\\\}"
_host="${_host//\\/\\\\}"
_cwd="${_cwd//\\/\\\\}"
_model="${_model//\\/\\\\}"
case "$current_effort" in
  low)    _effort_icon="○" ;;
  medium) _effort_icon="◐" ;;
  high)   _effort_icon="●" ;;
  xhigh)  _effort_icon="◉" ;;
  max)    _effort_icon="◈" ;;
  *)      _effort_icon="" ;;
esac
[ -n "$_effort_icon" ] && _model="${_model} \033[38;2;215;119;87m${_effort_icon}\033[0m"

_out="$_fmt"

# ── Optional groups [[ ... ]] (before tag substitution) ───────────────────────
#   A [[ ]] group survives iff at least one {tag} inside it expands to non-empty.
#   Scanned while tags are still literal — each {xxx} maps to the bash var _xxx
#   via indirect expansion (3.2-safe, no associative array). Brackets must be
#   quoted in every glob: bare [ is a character-class metacharacter that would
#   make the pattern silently never match (yet still pass bash -n).
while [[ "$_out" == *'[['* ]]; do
  _pre="${_out%%\[\[*}"      # text before the first [[
  _rest="${_out#*\[\[}"      # text after the first [[
  _grp="${_rest%%\]\]*}"     # group body (between [[ and ]])
  _post="${_rest#*\]\]}"     # text after the matching ]]
  _keep=0 _scan="$_grp"
  while [[ "$_scan" == *'{'* ]]; do
    _scan="${_scan#*\{}"; _tag="${_scan%%\}*}"; _scan="${_scan#*\}}"
    _vn="_$_tag"
    [ -n "${!_vn}" ] && { _keep=1; break; }
  done
  if [ "$_keep" = 1 ]; then
    _out="${_pre}${_grp}${_post}"
  else
    _out="${_pre}${_post}"
  fi
done

# ── Tag substitution: one left-to-right scan ──────────────────────────────────
#   Each {tag} expands once, in document order; a value is never scanned again.
#   Do not use one ${_out//\{tag\}/...} per tag: on bash 3.2 each one is
#   quadratic in the line length, and 16 of them over the growing line cost
#   ×60 for 4x segments. The whitelist keeps {out}, {i}... from leaking
#   internal variables. {sep}, {wrap}, unknown tags and a lone { stay literal.
_res="" _rest="$_out"
while [[ "$_rest" == *'{'* ]]; do
  _res+="${_rest%%\{*}"; _rest="${_rest#*\{}"
  _tag="${_rest%%\}*}"
  case "$_tag" in
    user|host|cwd|model|bar|pct|ctx|miss|next|total|spark|cache|delta|monthly|daily|5h|1w)
      if [ "$_tag" != "$_rest" ]; then  # a closing } exists
        _vn="_$_tag"; _res+="${!_vn}"; _rest="${_rest#*\}}"
        continue
      fi ;;
  esac
  _res+="{"
done
_out="$_res$_rest"

# ── Collapse empty {sep} segments (before the wrap/sep loop) ───────────────────
#   An emptied tag or a dropped [[ ]] group leaves an empty segment between two
#   {sep} tokens (or a dangling {sep} at an edge). Split on the still-literal
#   {sep}, drop blank segments, rejoin — so no doubled "│ │" or trailing "│".
#   Fork-free. ANSI codes are stripped before the emptiness check so that
#   color-wrapped empty tags don't masquerade as content.
shopt -s extglob
# Visible width of a segment: its length without the literal "\033[...X"
# escape text (_vlen), and without blanks too (_vlen_nb, "has content").
# Fork-free, linear in the number of escapes. Do not use
# ${1//\\033\[*([0-9;])[A-Za-z]/}: extglob *() in a global substitution is
# super-linear (~0.6 s on a 600-char line) and hangs the tick.
_vis_width() {
  local _r="$1" _vis="" _params
  while [[ "$_r" == *'\033['* ]]; do
    _vis+="${_r%%\\033\[*}"
    _r="${_r#*\\033\[}"
    _params="${_r%%[!0-9;]*}"
    _r="${_r:${#_params}+1}"
  done
  _vis+="$_r"
  _vlen=${#_vis}
  _vis="${_vis// /}"
  _vlen_nb=${#_vis}
}
if [[ "$_out" == *'{sep}'* ]]; then
  _collapsed="" _crest="$_out"
  while [[ "$_crest" == *'{sep}'* ]]; do
    _seg="${_crest%%\{sep\}*}"; _crest="${_crest#*\{sep\}}"
    _vis_width "$_seg"
    if [ "$_vlen_nb" -gt 0 ]; then
      [ -n "$_collapsed" ] && _collapsed="${_collapsed}{sep}${_seg}" || _collapsed="${_seg}"
    fi
  done
  _vis_width "$_crest"
  if [ "$_vlen_nb" -gt 0 ]; then
    [ -n "$_collapsed" ] && _collapsed="${_collapsed}{sep}${_crest}" || _collapsed="${_crest}"
  fi
  _out="$_collapsed"
fi

# ── Responsive wrap ───────────────────────────────────────────────────────────
#   {wrap} — soft break: renders as BURNBAR_WRAP_SEP (default "  ") or \n
#   {sep}  — group separator: renders as " │ " (BURNBAR_SEP char) or \n with no char
#   Both tags are processed left-to-right in document order.
if [[ "$_out" == *'{wrap}'* ]] || [[ "$_out" == *'{sep}'* ]]; then
  _detect_cols
  _wrap_inline="${BURNBAR_WRAP_SEP:-  }"
  _sep_inline="\033[90m${BURNBAR_SEP:-│}\033[0m"
  # Split into segments and the separators between them (document order).
  _segs=() _kinds=() _rest="$_out"
  while [[ "$_rest" == *'{wrap}'* ]] || [[ "$_rest" == *'{sep}'* ]]; do
    _bw="${_rest%%\{wrap\}*}"; _bs="${_rest%%\{sep\}*}"
    if [[ "$_rest" != *'{wrap}'* ]] || { [[ "$_rest" == *'{sep}'* ]] && [ "${#_bs}" -lt "${#_bw}" ]; }; then
      _segs+=("$_bs"); _kinds+=(sep); _rest="${_rest#*\{sep\}}"
    else
      _segs+=("$_bw"); _kinds+=(wrap); _rest="${_rest#*\{wrap\}}"
    fi
  done
  _segs+=("$_rest")
  # Greedy layout: each separator renders inline when the current line, the
  # separator and the next segment's first line fit in _term_cols - 2;
  # otherwise it becomes a newline. Each segment is measured once.
  _vis_width "$_sep_inline";  _sep_w=$_vlen
  _vis_width "$_wrap_inline"; _wrap_w=$_vlen
  _out="${_segs[0]}"
  _vis_width "${_out##*\\n}"; _line_w=$_vlen
  _i=0
  while [ "$_i" -lt "${#_kinds[@]}" ]; do
    _nxt="${_segs[$((_i + 1))]}"
    if [ "${_kinds[$_i]}" = sep ]; then _inline="$_sep_inline" _in_w=$_sep_w
    else _inline="$_wrap_inline" _in_w=$_wrap_w; fi
    _vis_width "${_nxt%%\\n*}"; _head_w=$_vlen
    if [ "$(( _line_w + _in_w + _head_w ))" -ge "$((_term_cols - 2))" ]; then
      _out="${_out}\\n${_nxt}"; _line_w=0
    else
      _out="${_out}${_inline}${_nxt}"; _line_w=$(( _line_w + _in_w ))
    fi
    if [[ "$_nxt" == *'\n'* ]]; then
      _vis_width "${_nxt##*\\n}"; _line_w=$_vlen
    else
      _line_w=$(( _line_w + _head_w ))
    fi
    _i=$((_i + 1))
  done
fi

printf '%b' "$_out"
