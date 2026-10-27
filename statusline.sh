#!/bin/bash
# Claude Pet status line: saves the status JSON (model, context, cost, rate limits)
# as ~/.claude/pet/status/<session_id>.json for the pet, and prints a compact line
# for the terminal.
dir="$HOME/.claude/pet/status"
input=$(cat)
[ -n "$input" ] || exit 0
mkdir -p "$dir"
sid=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id // empty')
case "$sid" in ""|*[!A-Za-z0-9_-]*) sid="unknown";; esac
# Walk up to the claude process so the pet can tell when the session is gone.
pid=$PPID
found=0
for _ in 1 2 3 4 5 6; do
  [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  comm=$(ps -o comm= -p "$pid"); comm=${comm##*/}
  case "$comm" in
    claude) found=1; break;;
    node) case "$(ps -o args= -p "$pid")" in *claude*) found=1; break;; esac;;
  esac
  pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
done
[ "$found" = 1 ] || pid=0
tmp="$dir/$sid.json.tmp.$$"
printf '%s' "$input" | /usr/bin/jq -c --argjson ts "$(date +%s)" --argjson pid "$pid" '. + {ts: $ts, pid: $pid}' > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$dir/$sid.json"
rm -f "$tmp"
# If a status line was configured before the pet was installed, keep showing that one.
orig="$HOME/.claude/pet/statusline.original"
if [ -s "$orig" ]; then printf '%s' "$input" | bash -c "$(cat "$orig")"; exit 0; fi
printf '%s' "$input" | /usr/bin/jq -r '
  def pct(x): (x | floor | tostring) + "%";
  [ (.model.display_name // .model.id // "Claude"),
    (if .context_window.used_percentage != null then "ctx " + pct(.context_window.used_percentage) else empty end),
    (if (.cost.total_cost_usd // 0) > 0 then "$" + ((.cost.total_cost_usd * 100 | round) / 100 | tostring) else empty end),
    (if .rate_limits.five_hour.used_percentage != null then "5h " + pct(.rate_limits.five_hour.used_percentage) else empty end),
    (if .rate_limits.seven_day.used_percentage != null then "wk " + pct(.rate_limits.seven_day.used_percentage) else empty end)
  ] | "\u001b[2m🐾 " + join("  ·  ") + "\u001b[0m"'
