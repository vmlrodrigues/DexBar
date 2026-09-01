#!/usr/bin/env bash
# Build a local Apple-silicon DexBar.app bundle.
#
#   ./Scripts/build.sh
#   SIGN=0 ./Scripts/build.sh

set -euo pipefail

APP_NAME="DexBar"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN="${SIGN:-0}"

echo "==> Building $APP_NAME $VERSION ($BUILD)"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/$APP_NAME"
[ -x "$BIN" ] || { echo "error: no binary at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi

if [ "$SIGN" = "1" ]; then
    IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
    [ -n "$IDENTITY" ] || { echo "error: no Developer ID Application identity" >&2; exit 1; }
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "Built: $APP"
