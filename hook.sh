#!/bin/bash
# Claude Pet hook: records the latest Claude Code hook event for each session as
# ~/.claude/pet/sessions/<session_id>.json. Registered in ~/.claude/settings.json.
# It must never print to stdout (some events inject stdout into Claude's context).
exec >/dev/null 2>&1
dir="$HOME/.claude/pet/sessions"
input=$(cat)
[ -n "$input" ] || exit 0

read -r sid event agent < <(printf '%s' "$input" | /usr/bin/jq -r \
  '[(.session_id // ""), (.hook_event_name // ""), (.agent_id // "")] | map(if . == "" then "-" else . end) | join(" ")')
[ -n "$sid" ] && [ "$sid" != "-" ] || exit 0
case "$sid" in *[!A-Za-z0-9_-]*) exit 0;; esac

# Tool events emitted by subagents carry the parent's session_id. The parent's own
# Agent tool call already marks the session as working, so skip them.
case "$event" in
  PreToolUse|PostToolUse|PostToolUseFailure) [ "$agent" = "-" ] || exit 0;;
esac

mkdir -p "$dir"
f="$dir/$sid.json"
if [ "$event" = "SessionEnd" ]; then rm -f "$f"; exit 0; fi

now=$(date +%s)
started=""
[ -f "$f" ] && started=$(/usr/bin/jq -r '.started // empty' "$f")
[ -n "$started" ] || started=$now

# Walk up the process tree to the claude process so the app can tell when the
# session has really gone away (0 = unknown, the app then uses a time limit).
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

tmp="$f.tmp.$$"
printf '%s' "$input" | /usr/bin/jq -c --argjson ts "$now" --argjson pid "$pid" --argjson started "$started" \
  '{ts: $ts, pid: $pid, started: $started,
    event: walk(if type == "string" and length > 400 then .[0:400] + "…" else . end)}' > "$tmp" \
  && mv -f "$tmp" "$f"
rm -f "$tmp"
exit 0
