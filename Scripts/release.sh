#!/usr/bin/env bash
# Validates that the notarised artifact corresponds exactly to pushed source and stages
# a GitHub release. Publishing is deliberately explicit: set PUBLISH=1.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/DexBar.app"
DMG="$ROOT/dist/DexBar.dmg"
REPO="${GITHUB_REPO:-vmlrodrigues/DexBar}"
REMOTE="${GIT_REMOTE:-origin}"

[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
[ -f "$DMG" ] || { echo "error: $DMG not found — run Scripts/notarize.sh" >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null
xcrun stapler validate "$DMG" >/dev/null
codesign --verify --strict --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --ignore-cache "$DMG"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"

if git -C "$ROOT" rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "error: v$VERSION already exists — bump VERSION before publishing" >&2
    exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "error: uncommitted or untracked files — commit the release source first" >&2
    git -C "$ROOT" status --short >&2
    exit 1
fi

HEAD_VERSION="$(git -C "$ROOT" show HEAD:VERSION | tr -d '[:space:]')"
[ "$HEAD_VERSION" = "$VERSION" ] \
    || { echo "error: VERSION at HEAD is $HEAD_VERSION but the app says $VERSION" >&2; exit 1; }
HEAD_BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
[ "$HEAD_BUILD" = "$BUILD" ] \
    || { echo "error: HEAD is build $HEAD_BUILD but the app is build $BUILD" >&2; exit 1; }

BRANCH="$(git -C "$ROOT" symbolic-ref --short HEAD)"
git -C "$ROOT" fetch --quiet "$REMOTE" "$BRANCH"
LOCAL_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
REMOTE_HEAD="$(git -C "$ROOT" rev-parse "$REMOTE/$BRANCH")"
[ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] || {
    echo "error: HEAD does not exactly match $REMOTE/$BRANCH — push before publishing" >&2
    exit 1
}

VERSIONED="$ROOT/dist/DexBar-$VERSION.dmg"
CHECKSUM="$ROOT/dist/DexBar-$VERSION.sha256"
cp "$DMG" "$VERSIONED"
(cd "$ROOT/dist" && shasum -a 256 "DexBar-$VERSION.dmg" > "DexBar-$VERSION.sha256")

if [ "${PUBLISH:-0}" != "1" ]; then
    cat <<EOF
Release candidate verified and staged:
  $VERSIONED
  $CHECKSUM

To publish this exact candidate:
  PUBLISH=1 ./Scripts/release.sh
EOF
    exit 0
fi

NOTES=(--generate-notes)
if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
    [ -f "$RELEASE_NOTES_FILE" ] \
        || { echo "error: RELEASE_NOTES_FILE not found: $RELEASE_NOTES_FILE" >&2; exit 1; }
    NOTES=(--notes-file "$RELEASE_NOTES_FILE")
fi

gh release create "v$VERSION" \
    "$VERSIONED#DexBar $VERSION (macOS, notarised)" \
    "$DMG#DexBar (latest, Apple Silicon)" \
    "$CHECKSUM#SHA-256 checksum" \
    --repo "$REPO" \
    --title "DexBar $VERSION" \
    "${NOTES[@]}"

echo "Published: https://github.com/$REPO/releases/tag/v$VERSION"
