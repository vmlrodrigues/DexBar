#!/usr/bin/env bash
# Notarises dist/DexBar.app, staples its ticket, and creates a signed, notarised DMG.
#
# Setup: copy .env.example to .env and fill it in, then run:
#
#   ./Scripts/build.sh
#   ./Scripts/notarize.sh

set -euo pipefail

APP_NAME="DexBar"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/build.sh first" >&2; exit 1; }
[ -f "$ENV_FILE" ] || {
    echo "error: no release environment at $ENV_FILE" >&2
    echo "       copy $ROOT/.env.example to $ROOT/.env and fill it in" >&2
    exit 1
}

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${NOTARY_KEY:?.env must set NOTARY_KEY (path to the App Store Connect .p8)}"
: "${NOTARY_KEY_ID:?.env must set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER:?.env must set NOTARY_ISSUER}"
IDENTITY="${RELEASE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "error: no Developer ID Application identity" >&2; exit 1; }
[ -f "$NOTARY_KEY" ] || { echo "error: NOTARY_KEY file not found: $NOTARY_KEY" >&2; exit 1; }

echo "==> Verifying the app signature"
codesign --verify --strict --verbose=2 "$APP"

ZIP="$DIST/$APP_NAME-app.zip"
echo "==> [1/2] Notarising the app"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --key "$NOTARY_KEY" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" \
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
    --key "$NOTARY_KEY" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" \
    --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --ignore-cache --verbose=4 "$DMG"

echo
echo "Distributable: $DMG"
