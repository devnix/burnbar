#!/bin/bash
# Burnbar — Rich statusline for Claude Code
# https://github.com/devnix/burnbar
#
# Configuration via environment variables:
#   BURNBAR_FORMAT      — format string with {tag} placeholders (see README for tags)
#   BURNBAR_BAR_WIDTH   — progress bar width in cells (default: 30)
#   BURNBAR_CACHE_WIDTH — cache bar width in cells (default: 10)

# ── Parse input (single jq call) ─────────────────────────────────────────────
input=$(cat)
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
  "current_effort=" + ((.effort.level // "") | @sh)
' <<< "$input") && eval "$jq_out"

# ── Pricing + model family ────────────────────────────────────────────────────
case "$model_id" in
  *opus*)
    price_in=15.0; price_cw=18.75; price_cr=1.50; model_family="opus"
    ;;
  *haiku*)
    price_in=0.80; price_cw=1.0; price_cr=0.08; model_family="haiku"
    ;;
  *sonnet*|*)
    price_in=3.0; price_cw=3.75; price_cr=0.30; model_family="sonnet"
    ;;
esac

# ── Header ────────────────────────────────────────────────────────────────────
_user="${USER:-$(whoami)}"
_host="${HOSTNAME%%.*}"
_cwd="$cwd"

# ── Cache timer: read timestamp before awk ────────────────────────────────────
BAR_WIDTH="${BURNBAR_BAR_WIDTH:-30}"
CACHE_TTL=300
CACHE_BAR_WIDTH="${BURNBAR_CACHE_WIDTH:-10}"
UNFILLED_BG="47"

cache_key="${session_id:0:8}"
ts_file="$HOME/.claude/.cache-ts-$cache_key"
remaining=0
has_cache=0
if [ -f "$ts_file" ]; then
  read -r last < "$ts_file" 2>/dev/null
  if ! [ "$last" -gt 0 ] 2>/dev/null; then last=0; fi
  if [ "$last" -gt 0 ] 2>/dev/null; then
    printf -v now '%(%s)T' -1
    elapsed=$((now - last))
    remaining=$((CACHE_TTL - elapsed))
    [ "$remaining" -lt 0 ] && remaining=0
    has_cache=1
  fi
fi

# ── Cache half-time notification ──────────────────────────────────────────────
#   Fires once per cache period when remaining crosses 50%.
#   BURNBAR_NOTIFY: auto|osc9|osc99|osc777|bell|none
#   Walks /proc tree to find parent pty (statusline has no /dev/tty).
_maybe_notify() {
  [ "$has_cache" = 1 ] && [ "$remaining" -gt 0 ] && [ "$remaining" -le $((CACHE_TTL / 2)) ] || return 0
  local _notif_file="$HOME/.claude/.cache-notif-$cache_key"
  if [ -f "$_notif_file" ]; then
    local _notif_ts; read -r _notif_ts < "$_notif_file" 2>/dev/null
    [ "$_notif_ts" = "$last" ] && return 0
  fi
  local _tty_dev="" _pid=$PPID _fd
  while [ "${_pid:-0}" -gt 1 ] 2>/dev/null; do
    _fd=$(readlink "/proc/$_pid/fd/1" 2>/dev/null) || break
    case "$_fd" in /dev/pts/*|/dev/tty*) _tty_dev="$_fd"; break ;; esac
    _pid=$(awk '{sub(/.*\) /, ""); print $2}' "/proc/$_pid/stat" 2>/dev/null) || break
  done
  [ -n "$_tty_dev" ] || return 0
  local _notif_msg _nm _sent=0
  printf -v _notif_msg 'Burnbar: cache 50%% — %d:%02d remaining' "$((remaining / 60))" "$((remaining % 60))"
  _nm="${BURNBAR_NOTIFY:-auto}"
  if [ "$_nm" = "auto" ]; then
    local _pref
    _pref=$(jq -r '.preferredNotifChannel // empty' "$HOME/.claude/settings.json" 2>/dev/null)
    if [ "$_pref" = "terminal_bell" ]; then
      _nm="bell"
    else
      case "${TERM_PROGRAM:-}" in
        ghostty)       _nm="osc777" ;;
        iTerm*|WezTerm) _nm="osc9" ;;
        *) [ -n "${KITTY_WINDOW_ID:-}" ] && _nm="osc99" || _nm="osc777" ;;
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

# ── All numeric computation (single awk call) ────────────────────────────────
read -r used_pct_int filled_full partial_idx ctx_fmt current_cost total_cost \
  cache_filled_full cache_partial_idx <<< "$(
  LC_NUMERIC=C awk -v pct="$used_pct" -v bw="$BAR_WIDTH" \
      -v it="$input_toks" -v cwt="$cw_toks" -v crt="$cr_toks" \
      -v pin="$price_in" -v pcw="$price_cw" -v pcr="$price_cr" \
      -v traw="$total_cost_raw" \
      -v rem="$remaining" -v ttl="$CACHE_TTL" -v cbw="$CACHE_BAR_WIDTH" \
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

    cost = (it * pin + cwt * pcw + crt * pcr) / 1000000
    cost = int(cost * 10000 + 0.5) / 10000

    tc = int(traw * 10000 + 0.5) / 10000

    if (ttl > 0 && rem > 0) {
      cf = rem / ttl * cbw
      if (cf > cbw) cf = cbw; if (cf < 0) cf = 0
      cff = int(cf)
      cpi = int((cf - cff) * 8)
      if (cpi > 7) cpi = 7; if (cpi < 0) cpi = 0
    } else { cff = 0; cpi = 0 }

    printf "%d %d %d %s %.4f %.4f %d %d", pct_int, ff, pi, cfmt, cost, tc, cff, cpi
  }'
)"

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
_next="next:\033[01;33m\$${current_cost}\033[00m"
_total="total:\033[01;31m\$${total_cost}\033[00m"

# ── Cache timer rendering ─────────────────────────────────────────────────────
_cache=""
if [ "$has_cache" = 1 ]; then
  cache_alert=""
  if [ -n "$session_id" ]; then
    meta_file="$HOME/.claude/.cache-meta-$cache_key"

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

  if [ "$remaining" -gt 120 ]; then
    cache_fg="32"; cache_bg="42"
  elif [ "$remaining" -gt 60 ]; then
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

# ── Format string and substitution engine ─────────────────────────────────────
_user="${_user//\\/\\\\}"
_host="${_host//\\/\\\\}"
_cwd="${_cwd//\\/\\\\}"
_model="${_model//\\/\\\\}"

_default_fmt='\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}  {bar}  {pct}  {ctx}  {next}  {total}  {cache}'
_out="${BURNBAR_FORMAT:-$_default_fmt}"

_out="${_out//\{user\}/$_user}"
_out="${_out//\{host\}/$_host}"
_out="${_out//\{cwd\}/$_cwd}"
_out="${_out//\{model\}/$_model}"
_out="${_out//\{bar\}/$_bar}"
_out="${_out//\{pct\}/$_pct}"
_out="${_out//\{ctx\}/$_ctx}"
_out="${_out//\{next\}/$_next}"
_out="${_out//\{total\}/$_total}"
_out="${_out//\{cache\}/$_cache}"

printf '%b' "$_out"
