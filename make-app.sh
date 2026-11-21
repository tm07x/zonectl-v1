#!/bin/bash
# Builds ZoneCapture with SwiftPM and assembles a launchable .app bundle.
# Usage: ./make-app.sh            -> builds and installs to /Applications
#        ./make-app.sh build       -> build only, leave bundle in build/ZoneCapture.app
set -euo pipefail

cd "$(dirname "$0")"

ACTION="${1:-install}"
ARCH="$(uname -m)"
APP_ROOT="$PWD/build"
APP_BUNDLE="$APP_ROOT/ZoneCapture.app"

stop_running_app() {
    # main.swift has a single-instance guard that exits immediately if another
    # copy is already running. Stop the existing process so the newly built
    # bundle actually takes over.
    osascript -e 'tell application id "com.grokink.zonecapture" to quit' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x ZoneCapture >/dev/null 2>&1 || return 0
        sleep 0.2
    done
    pkill -x ZoneCapture 2>/dev/null || true
    sleep 0.2
}

echo ">> Building with SwiftPM ($ARCH)…"
swift build -c release --arch "$ARCH"

BIN_PATH="$(swift build -c release --arch "$ARCH" --show-bin-path)"

echo ">> Assembling .app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/tools"

cp "$BIN_PATH/ZoneCapture" "$APP_BUNDLE/Contents/MacOS/ZoneCapture"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Bundle the Python page-extraction helper so the installed app can find it
# without depending on the repo being present.
cp "tools/zone_extract.py" "$APP_BUNDLE/Contents/Resources/tools/zone_extract.py"
cp "tools/requirements.txt" "$APP_BUNDLE/Contents/Resources/tools/requirements.txt"

# Bundle a self-contained Python environment. A GUI app's /usr/bin/env
# python3 resolves to the Command Line Tools interpreter, which has no
# readability/markdownify — without this, every ⌘⇧⌥L capture fails in the
# installed app. (Needs network access at build time for pip.)
echo ">> Creating bundled Python environment…"
VENV_DIR="$APP_BUNDLE/Contents/Resources/tools/venv"
python3 -m venv --copies "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet -r "tools/requirements.txt"
# Sanity: the bundled interpreter must actually import the dependencies.
"$VENV_DIR/bin/python3" -c "import readability, markdownify" \
    || { echo "!! bundled python cannot import extraction dependencies"; exit 1; }

# Sign nested native libraries before signing the outer bundle.
find "$VENV_DIR" -type f \( -name "*.so" -o -name "*.dylib" \) \
    -exec codesign --force --sign - {} \; 2>/dev/null || true

# Make the binary ad-hoc signed so Gatekeeper/local-first launch is happy.
codesign --force --sign - --entitlements Resources/ZoneCapture.entitlements "$APP_BUNDLE" 2>/dev/null || \
    codesign --force --sign - "$APP_BUNDLE"

if [ "$ACTION" = "build" ]; then
    echo ">> Done. Bundle: $APP_BUNDLE"
    stop_running_app
    open "$APP_BUNDLE" || true
    exit 0
fi

echo ">> Installing to /Applications/ZoneCapture.app"
stop_running_app
rm -rf "/Applications/ZoneCapture.app"
cp -a "$APP_BUNDLE" "/Applications/ZoneCapture.app"
echo ">> Launching…"
open "/Applications/ZoneCapture.app" || true
echo ">> Installed. Press Cmd+Shift+L to capture the frontmost browser URL."
