#!/bin/bash
# Removes the Claude Pet hooks, status line and login item. Pass --purge to also delete ~/.claude/pet.
set -euo pipefail
dest="$HOME/.claude/pet"
label="com.claudepet.app"
settings="$HOME/.claude/settings.json"
pkill -x ClaudePet 2>/dev/null || true
for l in "$label" com.hari.claudepet; do
  launchctl bootout "gui/$(id -u)/$l" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$l.plist"
done
if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
  orig=""; [ -s "$dest/statusline.original" ] && orig=$(cat "$dest/statusline.original")
  jq --arg cmd "$dest/hook.sh" --arg sl "$dest/statusline.sh" --arg orig "$orig" '
    .hooks = ((.hooks // {})
      | with_entries(.value |= (map(.hooks |= map(select(.command != $cmd))) | map(select((.hooks | length) > 0))))
      | with_entries(select((.value | length) > 0)))
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
    | (if .statusLine.command == $sl then (if $orig != "" then .statusLine = {"type": "command", "command": $orig} else del(.statusLine) end) else . end)
  ' "$settings" > "$settings.tmp" && mv -f "$settings.tmp" "$settings"
  echo "Removed the pet hooks and status line from $settings"
fi
if [ "${1:-}" = "--purge" ]; then rm -rf "$dest"; echo "Deleted $dest"; else echo "Kept $dest (run with --purge to delete it)."; fi
