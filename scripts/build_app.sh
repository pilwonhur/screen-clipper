#!/bin/bash
# Builds "Screen Clipper.app" into ~/Applications.
# Build files go to ~/Library/Caches/ScreenClipper (not Dropbox).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/ScreenClipper/build}"
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/Screen Clipper.app"
IDENTITY="${SIGN_IDENTITY:-}"

cd "$ROOT"
swift build -c release --scratch-path "$SCRATCH" --product ScreenClipper
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/ScreenClipper"

# Quit a running copy so it can be replaced.
pkill -x ScreenClipper 2>/dev/null && sleep 1 || true

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenClipper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# A stable signing identity keeps macOS permissions across rebuilds.
# Without one (ad-hoc), you may need to re-grant Screen Recording/Accessibility after each rebuild.
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "Screen Clipper Dev"; then
  IDENTITY="Screen Clipper Dev"
fi
codesign --force --sign "${IDENTITY:--}" --identifier com.pilwonhur.screenclipper "$APP"
echo "Built: $APP (signed with ${IDENTITY:-ad-hoc})"
