#!/bin/sh
# Burnbar — Rich statusline for Claude Code
# https://github.com/devnix/burnbar

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')
model=$(echo "$input" | jq -r '.model.display_name')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')

used_pct_display=$(echo "$used_pct" | awk '{printf "%.0f", $1}')

# Current context tokens = input + cache_creation + cache_read (all input token types)
# input_tokens alone is only non-cached tokens; with prompt cache active it can be 1
current_ctx_tokens=$(echo "$input" | jq -r '
  if .context_window.current_usage != null then
    ((.context_window.current_usage.input_tokens // 0) +
     (.context_window.current_usage.cache_creation_input_tokens // 0) +
     (.context_window.current_usage.cache_read_input_tokens // 0))
  else 0 end
')

# Total tokens in session (input + output, cumulative)
total_tokens=$(echo "$input" | jq -r '
  (.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0)
')

# Detect model family from model.id and select pricing accordingly
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

# Use the authoritative total cost provided directly by Claude Code
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0 | . * 10000 | round | . / 10000')

# Calculate cost of sending the current message (current context input cost)
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

# ── Progress bar (background colors + partial blocks) ─────────────────────────
# Gradient: green (0-49%) → yellow (50-79%) → red (80-100%)
# Uses background colors (survive Claude Code dimming) for filled/unfilled,
# partial block characters (▏▎▍▌▋▊▉) at the transition cell.

BAR_WIDTH=30

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
    if (pct < 50)      print "42"    # green bg  (0-49%)
    else if (pct < 80) print "43"    # yellow bg (50-79%)
    else                print "41"    # red bg    (80-100%)
  }'
}

cell_fg() {
  echo "$1 $2" | awk '{
    pct = ($1 + 0.5) / $2 * 100
    if (pct < 50)      print "32"    # green fg
    else if (pct < 80) print "33"    # yellow fg
    else                print "31"    # red fg
  }'
}

UNFILLED_BG="47"   # white bg → after Claude Code dimming becomes light gray

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

# ── Token count with color matching bar gradient ──
ctx_tokens_fmt=$(echo "$current_ctx_tokens" | awk '{
  if ($1 >= 1000) printf "%.1fk", $1/1000
  else            printf "%d",    $1
}')

used_pct_int=$(echo "$used_pct" | awk '{printf "%.0f", $1}')
if [ "$used_pct_int" -ge 80 ] 2>/dev/null; then
  tokens_colored="\033[01;31m${ctx_tokens_fmt}\033[00m"
elif [ "$used_pct_int" -ge 50 ] 2>/dev/null; then
  tokens_colored="\033[01;33m${ctx_tokens_fmt}\033[00m"
else
  tokens_colored="\033[01;32m${ctx_tokens_fmt}\033[00m"
fi

# ── Output ──
printf '\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m\n%s  ' \
  "$(whoami)" "$(hostname -s)" "$cwd" "$model"
printf "${bar}"
printf "  %s%%  ctx:${tokens_colored}  next:\033[01;33m\$%s\033[00m  total:\033[01;31m\$%s\033[00m" \
  "$used_pct_display" "$current_cost" "$total_cost"
