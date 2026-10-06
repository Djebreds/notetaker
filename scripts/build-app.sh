#!/usr/bin/env bash
# Builds Minutes.app, signs it with your Apple Development identity (so macOS
# remembers its permissions across rebuilds), installs it to ~/Applications and
# launches it through Launch Services (so permission prompts are attributed to
# Minutes, not to the terminal).
#
# Usage: scripts/build-app.sh [release|debug] [--no-launch]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
LAUNCH=1
[[ "${2:-}" == "--no-launch" ]] && LAUNCH=0

swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="build/Minutes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Minutes" "$APP/Contents/MacOS/Minutes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# SwiftPM resource bundles of dependencies (FluidAudio's): looked up in Contents/Resources.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

IDENTITY="${MINUTES_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
  echo "No Apple Development signing identity found. Set MINUTES_SIGN_IDENTITY." >&2
  exit 1
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

DEST="$HOME/Applications/Minutes.app"
mkdir -p "$HOME/Applications"
if pgrep -x Minutes >/dev/null; then
  osascript -e 'tell application id "com.refifauzan.minutes" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Minutes >/dev/null || break; sleep 0.5; done
  pkill -x Minutes 2>/dev/null || true
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST (signed by: $IDENTITY)"

if (( LAUNCH )); then
  open "$DEST"
fi
