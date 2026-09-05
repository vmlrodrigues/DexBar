#!/usr/bin/env bash
# Notarises dist/DexBar.app, staples its ticket, and creates a signed, notarised DMG.
#
# Setup: store validated credentials in the macOS Keychain once, then run:
#
#   xcrun notarytool store-credentials PersonalProjectsNotary --sync
#   BUILD_CHANNEL=release SIGN=1 ./Scripts/build.sh
#   ./Scripts/notarize.sh

set -euo pipefail

APP_NAME="DexBar"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
NOTARY_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-PersonalProjectsNotary}"

[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/build.sh first" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
CHANNEL="$(plist DexBarBuildChannel)"
[ "$CHANNEL" = "release" ] \
    || { echo "error: app build channel is '$CHANNEL', expected release" >&2; exit 1; }
SOURCE_REVISION="$(plist DexBarSourceRevision)"
CURRENT_REVISION="$(git -C "$ROOT" rev-parse --verify HEAD)"
[ "$SOURCE_REVISION" = "$CURRENT_REVISION" ] \
    || { echo "error: app was built from $SOURCE_REVISION but HEAD is $CURRENT_REVISION" >&2; exit 1; }
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ] \
    || { echo "error: release source has uncommitted or untracked files" >&2; exit 1; }

IDENTITY="${RELEASE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "error: no Developer ID Application identity" >&2; exit 1; }

echo "==> Validating Apple notary credentials ($NOTARY_PROFILE)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || { echo "error: Keychain notary profile '$NOTARY_PROFILE' is missing or invalid" >&2; exit 1; }

echo "==> Verifying the app signature"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q '^Authority=Developer ID Application:' \
    || { echo "error: app is not signed with a Developer ID Application identity" >&2; exit 1; }

ZIP="$DIST/$APP_NAME-app.zip"
echo "==> [1/2] Notarising the app"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --ignore-cache --verbose=4 "$APP"

echo "==> [2/2] Building and notarising the DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --ignore-cache --verbose=4 "$DMG"

echo
echo "Distributable: $DMG"
