#!/bin/bash
# Builds ~/Applications/Claude Traffic Light.app from Sources/ and (re)starts it:
# through its LaunchAgent when that is installed, otherwise with open.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/Claude Traffic Light.app"
label="com.artembobkin.claude-traffic-light"

mkdir -p "$app/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx15.0 \
  "$here/Sources/main.swift" \
  -o "$app/Contents/MacOS/ClaudeTrafficLight"
cp "$here/Sources/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null 2>&1 || true

if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$label"
else
  open "$app"
fi
echo "built $app"
