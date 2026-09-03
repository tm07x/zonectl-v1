#!/bin/bash
# Builds ZoneCapture with SwiftPM and assembles a launchable .app bundle.
# Usage: ./make-app.sh            -> builds and installs to /Applications
#        ./make-app.sh build       -> build only, leave bundle in build/ZoneCapture.app
set -euo pipefail

cd "$(dirname "$0")"

ACTION="${1:-install}"
APP_ROOT="$PWD/build"
APP_BUNDLE="$APP_ROOT/ZoneCapture.app"

echo ">> Building with SwiftPM…"
swift build -c release --arch arm64

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"

echo ">> Assembling .app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH/ZoneCapture" "$APP_BUNDLE/Contents/MacOS/ZoneCapture"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Make the binary ad-hoc signed so Gatekeeper/local-first launch is happy.
codesign --force --sign - --entitlements Resources/ZoneCapture.entitlements "$APP_BUNDLE" 2>/dev/null || \
    codesign --force --sign - "$APP_BUNDLE"

if [ "$ACTION" = "build" ]; then
    echo ">> Done. Bundle: $APP_BUNDLE"
    open "$APP_BUNDLE" || true
    exit 0
fi

echo ">> Installing to /Applications/ZoneCapture.app"
rm -rf "/Applications/ZoneCapture.app"
cp -R "$APP_BUNDLE" "/Applications/ZoneCapture.app"
echo ">> Launching…"
open "/Applications/ZoneCapture.app" || true
echo ">> Installed. Press Cmd+Shift+L to capture the frontmost browser URL."
