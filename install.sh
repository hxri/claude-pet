#!/bin/bash
# Claude Pet installer. Copies this folder to ~/.claude/pet (if run from elsewhere),
# builds the app, registers the Claude Code hooks + status line, and starts the pet.
# Safe to re-run: it never duplicates hooks and keeps your existing status line.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.claude/pet"
label="com.claudepet.app"

if ! command -v swiftc >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Install the Xcode Command Line Tools first:"
  echo "    xcode-select --install"
  echo "then run this script again."; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is missing (it ships with macOS 15+). Install it with:  brew install jq"; exit 1
fi
command -v claude >/dev/null 2>&1 || echo "Note: 'claude' is not on PATH. The pet will nap until Claude Code is installed."

if [ "$src" != "$dest" ]; then
  mkdir -p "$dest"
  rsync -a --exclude ClaudePet.app --exclude sessions --exclude status --exclude .git --exclude 'control*' --exclude 'net-state*' "$src/" "$dest/"
fi
cd "$dest"
chmod +x hook.sh statusline.sh build.sh install.sh uninstall.sh
mkdir -p sessions status control
echo "Building…"
./build.sh >/dev/null

settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -s "$settings" ] || echo '{}' > "$settings"
jq empty "$settings" 2>/dev/null || { echo "$settings is not valid JSON; please fix it and re-run."; exit 1; }
cp "$settings" "$dest/settings.json.bak-$(date +%Y%m%d-%H%M%S)"

# Keep a pre-existing status line: ours saves the JSON and then shows the original.
cur=$(jq -r '.statusLine.command // empty' "$settings")
if [ -n "$cur" ] && [ "$cur" != "$dest/statusline.sh" ]; then printf '%s' "$cur" > "$dest/statusline.original"; fi

jq --arg cmd "$dest/hook.sh" --arg sl "$dest/statusline.sh" '
  def entry($t): {"hooks": [{"type": "command", "command": $cmd, "timeout": $t}]};
  def has($e): ((.hooks[$e] // []) | map((.hooks // []) | any(.command == $cmd)) | any);
  .hooks = (.hooks // {})
  | reduce ("SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure","PreCompact") as $e
      (.; if has($e) then . else .hooks[$e] = ((.hooks[$e] // []) + [entry(10)]) end)
  | (if has("SessionEnd") then . else .hooks["SessionEnd"] = ((.hooks["SessionEnd"] // []) + [entry(5)]) end)
  | .statusLine = {"type": "command", "command": $sl}
' "$settings" > "$settings.tmp" && mv -f "$settings.tmp" "$settings"

# Start at login (and right now).
mkdir -p "$HOME/Library/LaunchAgents"
for old in com.hari.claudepet; do
  launchctl bootout "gui/$(id -u)/$old" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$old.plist"
done
plist="$HOME/Library/LaunchAgents/$label.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$dest/ClaudePet.app/Contents/MacOS/ClaudePet</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
pkill -x ClaudePet 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
sleep 0.3
launchctl bootstrap "gui/$(id -u)" "$plist"

echo
echo "Claude Pet is running. Right-click it to name it and pick a pet, coat and size."
echo "Claude Code sessions that were already open start reporting after their next prompt"
echo "(or restart them). To remove everything later: $dest/uninstall.sh"
