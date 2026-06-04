#!/bin/bash
# Burnbar — Rich statusline for Claude Code
# https://github.com/devnix/burnbar
#
# Configuration via environment variables:
#   BURNBAR_FORMAT   — format string with {tag} placeholders (see README for tags)
#   BURNBAR_BAR_WIDTH — progress bar width in cells (default: 30)

# ── Parse input ───────────────────────────────────────────────────────────────
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
used_pct_display=$(echo "$used_pct" | awk '{printf "%.0f", $1}')
used_pct_int=$(echo "$used_pct" | awk '{printf "%.0f", $1}')

# ── Color for current usage level ─────────────────────────────────────────────
if [ "$used_pct_int" -ge 80 ] 2>/dev/null; then
  level_fg="31"; level_bold="01;31"
elif [ "$used_pct_int" -ge 50 ] 2>/dev/null; then
  level_fg="33"; level_bold="01;33"
else
  level_fg="32"; level_bold="01;32"
fi

# ── Header components ─────────────────────────────────────────────────────────
_user=$(whoami)
_host=$(hostname -s)
_cwd="$cwd"

# ── Model name ────────────────────────────────────────────────────────────────
_model=$(echo "$input" | jq -r '.model.display_name')

# ── Progress bar ──────────────────────────────────────────────────────────────
BAR_WIDTH="${BURNBAR_BAR_WIDTH:-30}"

filled_exact=$(echo "$used_pct $BAR_WIDTH" | awk '{
  cells = $1 / 100 * $2
  if (cells > $2) cells = $2
  if (cells < 0)  cells = 0
  printf "%.4f", cells
}')

filled_full=$(echo "$filled_exact" | awk '{print int($1)}')

partial_idx=$(echo "$filled_exact $filled_full" | awk '{
  frac = $1 - $2
  idx = int(frac * 8)
  if (idx > 7) idx = 7
  if (idx < 0) idx = 0
  print idx
}')

cell_bg() {
  echo "$1 $2" | awk '{
    pct = ($1 + 0.5) / $2 * 100
    if (pct < 50)      print "42"
    else if (pct < 80) print "43"
    else                print "41"
  }'
}

cell_fg() {
  echo "$1 $2" | awk '{
    pct = ($1 + 0.5) / $2 * 100
    if (pct < 50)      print "32"
    else if (pct < 80) print "33"
    else                print "31"
  }'
}

UNFILLED_BG="47"

bar=""
i=0
while [ "$i" -lt "$BAR_WIDTH" ]; do
  if [ "$i" -lt "$filled_full" ]; then
    bg=$(cell_bg "$i" "$BAR_WIDTH")
    bar="${bar}\033[${bg}m \033[0m"
  elif [ "$i" -eq "$filled_full" ] && [ "$filled_full" -lt "$BAR_WIDTH" ]; then
    fg=$(cell_fg "$i" "$BAR_WIDTH")
    case "$partial_idx" in
      0) bar="${bar}\033[${UNFILLED_BG}m \033[0m" ;;
      1) bar="${bar}\033[${fg};${UNFILLED_BG}m▏\033[0m" ;;
      2) bar="${bar}\033[${fg};${UNFILLED_BG}m▎\033[0m" ;;
      3) bar="${bar}\033[${fg};${UNFILLED_BG}m▍\033[0m" ;;
      4) bar="${bar}\033[${fg};${UNFILLED_BG}m▌\033[0m" ;;
      5) bar="${bar}\033[${fg};${UNFILLED_BG}m▋\033[0m" ;;
      6) bar="${bar}\033[${fg};${UNFILLED_BG}m▊\033[0m" ;;
      7) bar="${bar}\033[${fg};${UNFILLED_BG}m▉\033[0m" ;;
    esac
  else
    bar="${bar}\033[${UNFILLED_BG}m \033[0m"
  fi
  i=$((i + 1))
done
_bar="$bar"

# ── Percentage ────────────────────────────────────────────────────────────────
_pct="${used_pct_display}%"

# ── Context tokens ────────────────────────────────────────────────────────────
current_ctx_tokens=$(echo "$input" | jq -r '
  if .context_window.current_usage != null then
    ((.context_window.current_usage.input_tokens // 0) +
     (.context_window.current_usage.cache_creation_input_tokens // 0) +
     (.context_window.current_usage.cache_read_input_tokens // 0))
  else 0 end
')

ctx_tokens_fmt=$(echo "$current_ctx_tokens" | awk '{
  if ($1 >= 1000) printf "%.1fk", $1/1000
  else            printf "%d",    $1
}')

_ctx="ctx:\033[${level_bold}m${ctx_tokens_fmt}\033[00m"

# ── Pricing (shared by next and total) ────────────────────────────────────────
model_id=$(echo "$input" | jq -r '.model.id // "" | ascii_downcase')
case "$model_id" in
  *opus*)
    price_in=15.0; price_cw=18.75; price_cr=1.50
    ;;
  *haiku*)
    price_in=0.80; price_cw=1.0; price_cr=0.08
    ;;
  *sonnet*|*)
    price_in=3.0; price_cw=3.75; price_cr=0.30
    ;;
esac

# ── Next message cost ─────────────────────────────────────────────────────────
current_cost=$(echo "$input" | jq -r \
  --argjson pin "$price_in" \
  --argjson pcw "$price_cw" \
  --argjson pcr "$price_cr" '
  if .context_window.current_usage != null then
    ((.context_window.current_usage.input_tokens // 0) * $pin / 1000000 +
     (.context_window.current_usage.cache_creation_input_tokens // 0) * $pcw / 1000000 +
     (.context_window.current_usage.cache_read_input_tokens // 0) * $pcr / 1000000) |
    . * 10000 | round | . / 10000
  else
    0
  end
')

_next="next:\033[01;33m\$${current_cost}\033[00m"

# ── Total session cost ────────────────────────────────────────────────────────
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0 | . * 10000 | round | . / 10000')

_total="total:\033[01;31m\$${total_cost}\033[00m"

# ── Format string and substitution engine ────────────────────────────────────
_default_fmt='\033[01;32m{user}@{host}\033[00m:\033[01;34m{cwd}\033[00m\n{model}  {bar}  {pct}  {ctx}  {next}  {total}'
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

printf '%b' "$_out"
