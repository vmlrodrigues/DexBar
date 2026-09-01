#!/usr/bin/env bash
# Builds DexBar.app and signs it with a Developer ID identity.
#
#   ./Scripts/build.sh          release build, signed
#   SIGN=0 ./Scripts/build.sh   ad-hoc signing for local testing
#
# VERSION changes only when cutting a release. BUILD is the git commit count so it is
# monotonic and reproducible; release builds never silently invent a fallback number.
# Notarisation and DMG packaging are separate — see Scripts/notarize.sh.

set -euo pipefail

APP_NAME="DexBar"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null)}"
[ -n "$VERSION" ] || { echo "error: no VERSION file at $ROOT/VERSION" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
    || { echo "error: invalid VERSION '$VERSION'" >&2; exit 1; }

if [ -z "${BUILD:-}" ]; then
    git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1 \
        || { echo "error: DexBar must be built from a Git commit, or BUILD must be set explicitly" >&2; exit 1; }
    BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
fi
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid BUILD '$BUILD'" >&2; exit 1; }

SIGN="${SIGN:-1}"
[[ "$SIGN" = "0" || "$SIGN" = "1" ]] || { echo "error: SIGN must be 0 or 1" >&2; exit 1; }

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
    echo "==> Gatekeeper assessment (expected to fail until notarised):"
    spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true
else
    echo "==> Ad-hoc signing for local use"
    codesign --force --sign - "$APP"
fi

echo
echo "Built: $APP"
du -sh "$APP" | awk '{print "Size:  " $1}'
