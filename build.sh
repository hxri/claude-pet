#!/bin/bash
# Builds ~/.claude/pet/ClaudePet.app from ClaudePet.swift. Pass --restart to relaunch it.
set -euo pipefail
cd "$(dirname "$0")"
app=ClaudePet.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Pet</string>
  <key>CFBundleDisplayName</key><string>Claude Pet</string>
  <key>CFBundleIdentifier</key><string>com.claudepet.app</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundleIconFile</key><string>ClaudePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Claude Pet looks for your friends' pets nearby so your pets can visit each other.</string>
  <key>NSBonjourServices</key><array><string>_claudepet._tcp</string></array>
</dict>
</plist>
PLIST
swiftc -O -framework Cocoa -o "$app/Contents/MacOS/ClaudePet" ClaudePet.swift
mkdir -p "$app/Contents/Resources/pets"
cp pets/*.json "$app/Contents/Resources/pets/" 2>/dev/null || true
# App icon rendered from the pet itself.
if [ ! -f "$app/Contents/Resources/ClaudePet.icns" ] || [ ClaudePet.swift -nt "$app/Contents/Resources/ClaudePet.icns" ]; then
  tmp=$(mktemp -d)
  "$app/Contents/MacOS/ClaudePet" --render ready "$tmp/base.png" - 512 rabbit
  mkdir -p "$tmp/icon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/base.png" --out "$tmp/icon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$tmp/base.png" --out "$tmp/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/icon.iconset" -o "$app/Contents/Resources/ClaudePet.icns" || true
  rm -rf "$tmp"
fi
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "built $PWD/$app"
if [ "${1:-}" = "--restart" ]; then
  pkill -x ClaudePet 2>/dev/null || true
  sleep 0.4
  open "$app"
  echo "relaunched"
fi
