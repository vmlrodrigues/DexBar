#!/usr/bin/env bash
# Validates that the notarised artifact corresponds exactly to pushed source and stages
# a GitHub release. Publishing is deliberately explicit: set PUBLISH=1.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/DexBar.app"
DMG="$ROOT/dist/DexBar.dmg"
APPCAST="$ROOT/appcast.xml"
REPO="${GITHUB_REPO:-vmlrodrigues/DexBar}"
REMOTE="${GIT_REMOTE:-origin}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-DexBar}"

[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
[ -f "$DMG" ] || { echo "error: $DMG not found — run Scripts/notarize.sh" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
CHANNEL="$(plist DexBarBuildChannel)"
SOURCE_REVISION="$(plist DexBarSourceRevision)"
[ "$CHANNEL" = "release" ] \
    || { echo "error: app build channel is '$CHANNEL', expected release" >&2; exit 1; }
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40,64}$ ]] \
    || { echo "error: app has invalid source revision '$SOURCE_REVISION'" >&2; exit 1; }
git -C "$ROOT" cat-file -e "$SOURCE_REVISION^{commit}" 2>/dev/null \
    || { echo "error: app source revision $SOURCE_REVISION is not in this repository" >&2; exit 1; }

SOURCE_VERSION="$(git -C "$ROOT" show "$SOURCE_REVISION:VERSION" | tr -d '[:space:]')"
[ "$SOURCE_VERSION" = "$VERSION" ] \
    || { echo "error: VERSION at $SOURCE_REVISION is $SOURCE_VERSION but the app says $VERSION" >&2; exit 1; }
SOURCE_BUILD="$(git -C "$ROOT" rev-list --count "$SOURCE_REVISION")"
[ "$SOURCE_BUILD" = "$BUILD" ] \
    || { echo "error: source revision is build $SOURCE_BUILD but the app is build $BUILD" >&2; exit 1; }

CURRENT_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
APPCAST_COMMIT=0
if [ "$CURRENT_HEAD" != "$SOURCE_REVISION" ]; then
    PARENT="$(git -C "$ROOT" rev-parse HEAD^ 2>/dev/null || true)"
    SUBJECT="$(git -C "$ROOT" show -s --format=%s HEAD)"
    if [ "$PARENT" = "$SOURCE_REVISION" ] \
        && [ "$SUBJECT" = "Publish DexBar $VERSION appcast" ]; then
        APPCAST_COMMIT=1
    else
        echo "error: HEAD is neither the app source revision nor its appcast publication commit" >&2
        exit 1
    fi
fi
DIRTY_STATUS="$(git -C "$ROOT" status --porcelain --untracked-files=normal)"
if [ -n "$DIRTY_STATUS" ]; then
    case "$DIRTY_STATUS" in
        " M appcast.xml"|"M  appcast.xml"|"MM appcast.xml")
            [ "$APPCAST_COMMIT" = "0" ] || {
                echo "error: appcast publication commit has additional working-tree changes" >&2
                exit 1
            }
            ;;
        *)
            echo "error: uncommitted or untracked files — commit the release source first" >&2
            git -C "$ROOT" status --short >&2
            exit 1
            ;;
    esac
fi

xcrun stapler validate "$APP" >/dev/null
xcrun stapler validate "$DMG" >/dev/null
codesign --verify --strict --deep --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --ignore-cache "$DMG"

BRANCH="$(git -C "$ROOT" symbolic-ref --short HEAD)"
git -C "$ROOT" fetch --quiet "$REMOTE" "$BRANCH"
REMOTE_HEAD="$(git -C "$ROOT" rev-parse "$REMOTE/$BRANCH")"
if [ "$APPCAST_COMMIT" = "0" ]; then
    [ "$REMOTE_HEAD" = "$SOURCE_REVISION" ] || {
        echo "error: source revision does not exactly match $REMOTE/$BRANCH — push before publishing" >&2
        exit 1
    }
else
    [ "$REMOTE_HEAD" = "$SOURCE_REVISION" ] || [ "$REMOTE_HEAD" = "$CURRENT_HEAD" ] || {
        echo "error: $REMOTE/$BRANCH moved beyond the resumable appcast publication" >&2
        exit 1
    }
fi

VERSIONED="$ROOT/dist/DexBar-$VERSION.dmg"
CHECKSUM="$ROOT/dist/DexBar-$VERSION.sha256"
APPCAST_CANDIDATE="$ROOT/dist/appcast.xml"
cp "$DMG" "$VERSIONED"
(cd "$ROOT/dist" && shasum -a 256 "DexBar-$VERSION.dmg" > "DexBar-$VERSION.sha256")

SIGN_UPDATE="$(find "$ROOT/.build/artifacts/sparkle" -type f -name sign_update 2>/dev/null \
    | sed -n '1p')"
[ -x "$SIGN_UPDATE" ] \
    || { echo "error: Sparkle sign_update not found — run 'swift package resolve'" >&2; exit 1; }
GENERATE_KEYS="$(dirname "$SIGN_UPDATE")/generate_keys"
[ -x "$GENERATE_KEYS" ] \
    || { echo "error: Sparkle generate_keys not found beside sign_update" >&2; exit 1; }

EMBEDDED_PUBLIC_KEY="$(plist SUPublicEDKey | tr -d '[:space:]')"
SIGNING_PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p | tr -d '[:space:]')"
[ -n "$EMBEDDED_PUBLIC_KEY" ] && [ "$SIGNING_PUBLIC_KEY" = "$EMBEDDED_PUBLIC_KEY" ] || {
    echo "error: Sparkle account '$SPARKLE_ACCOUNT' does not match the public key in the app" >&2
    echo "       embedded: $EMBEDDED_PUBLIC_KEY" >&2
    echo "       keychain: $SIGNING_PUBLIC_KEY" >&2
    exit 1
}

echo "==> Signing DexBar $VERSION for Sparkle"
SIG_ATTRS="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$VERSIONED")"
git -C "$ROOT" show "$SOURCE_REVISION:appcast.xml" > "$APPCAST_CANDIDATE"
PUB_DATE="$(LC_ALL=C git -C "$ROOT" show -s --format=%cD "$SOURCE_REVISION")"
python3 "$ROOT/Scripts/appcast-add.py" \
    --appcast "$APPCAST_CANDIDATE" \
    --short-version "$VERSION" \
    --version "$BUILD" \
    --url "https://github.com/$REPO/releases/download/v$VERSION/DexBar-$VERSION.dmg" \
    --sig-attrs "$SIG_ATTRS" \
    --min-system "$(plist LSMinimumSystemVersion)" \
    --link "https://github.com/$REPO/releases/tag/v$VERSION" \
    --pub-date "$PUB_DATE"

if [ -n "$DIRTY_STATUS" ]; then
    case "$DIRTY_STATUS" in
        " M appcast.xml"|"M  appcast.xml"|"MM appcast.xml")
            [ "$APPCAST_COMMIT" = "0" ] && cmp -s "$APPCAST" "$APPCAST_CANDIDATE" || {
                echo "error: working tree changes are not the staged DexBar $VERSION appcast" >&2
                git -C "$ROOT" status --short >&2
                exit 1
            }
            ;;
        *)
            echo "error: uncommitted or untracked files — commit the release source first" >&2
            git -C "$ROOT" status --short >&2
            exit 1
            ;;
    esac
fi

if [ "$APPCAST_COMMIT" = "1" ]; then
    cmp -s <(git -C "$ROOT" show HEAD:appcast.xml) "$APPCAST_CANDIDATE" || {
        echo "error: the existing appcast commit does not match this release candidate" >&2
        exit 1
    }
fi

if [ "${PUBLISH:-0}" != "1" ]; then
    cat <<EOF
Release candidate verified and staged:
  $VERSIONED
  $CHECKSUM
  $APPCAST_CANDIDATE

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

REMOTE_TAG_SHA="$(git -C "$ROOT" ls-remote "$REMOTE" \
    "refs/tags/v$VERSION" "refs/tags/v$VERSION^{}" | tail -1 | awk '{print $1}')"

if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "==> Resuming existing GitHub release v$VERSION"
    [ -n "$REMOTE_TAG_SHA" ] && [ "$REMOTE_TAG_SHA" = "$SOURCE_REVISION" ] || {
        echo "error: existing v$VERSION tag does not point at $SOURCE_REVISION" >&2
        exit 1
    }
    IS_DRAFT="$(gh release view "v$VERSION" --repo "$REPO" --json isDraft --jq '.isDraft')"
    [ "$IS_DRAFT" = "false" ] \
        || { echo "error: existing v$VERSION release is still a draft" >&2; exit 1; }

    ASSETS="$(gh release view "v$VERSION" --repo "$REPO" --json assets --jq '.assets[].name')"
    if ! grep -Fxq "DexBar-$VERSION.dmg" <<<"$ASSETS"; then
        gh release upload "v$VERSION" "$VERSIONED#DexBar $VERSION (macOS, notarised)" --repo "$REPO"
    fi
    if ! grep -Fxq "DexBar.dmg" <<<"$ASSETS"; then
        gh release upload "v$VERSION" "$DMG#DexBar (latest, Apple Silicon)" --repo "$REPO"
    fi
    if ! grep -Fxq "DexBar-$VERSION.sha256" <<<"$ASSETS"; then
        gh release upload "v$VERSION" "$CHECKSUM#SHA-256 checksum" --repo "$REPO"
    fi

    VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/DexBar-release.XXXXXX")"
    cleanup() {
        if [ -n "${VERIFY_DIR:-}" ] && [ -d "$VERIFY_DIR" ]; then
            rm -rf "$VERIFY_DIR"
        fi
    }
    trap cleanup EXIT
    gh release download "v$VERSION" --repo "$REPO" --dir "$VERIFY_DIR" \
        --pattern "DexBar-$VERSION.dmg" --pattern "DexBar.dmg" \
        --pattern "DexBar-$VERSION.sha256"
    cmp -s "$VERSIONED" "$VERIFY_DIR/DexBar-$VERSION.dmg" \
        || { echo "error: published versioned DMG differs from this candidate" >&2; exit 1; }
    cmp -s "$DMG" "$VERIFY_DIR/DexBar.dmg" \
        || { echo "error: published latest DMG differs from this candidate" >&2; exit 1; }
    cmp -s "$CHECKSUM" "$VERIFY_DIR/DexBar-$VERSION.sha256" \
        || { echo "error: published checksum differs from this candidate" >&2; exit 1; }
else
    [ -z "$REMOTE_TAG_SHA" ] \
        || { echo "error: remote tag v$VERSION exists without a GitHub release" >&2; exit 1; }
    gh release create "v$VERSION" \
        "$VERSIONED#DexBar $VERSION (macOS, notarised)" \
        "$DMG#DexBar (latest, Apple Silicon)" \
        "$CHECKSUM#SHA-256 checksum" \
        --repo "$REPO" \
        --target "$SOURCE_REVISION" \
        --title "DexBar $VERSION" \
        "${NOTES[@]}"
fi

if [ "$APPCAST_COMMIT" = "0" ]; then
    cp "$APPCAST_CANDIDATE" "$APPCAST"

    echo "==> Committing the update feed"
    git -C "$ROOT" add appcast.xml
    git -C "$ROOT" commit -m "Publish DexBar $VERSION appcast"
fi

echo "==> Publishing the update feed"
git -C "$ROOT" push "$REMOTE" "$BRANCH"

LOCAL_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
git -C "$ROOT" fetch --quiet "$REMOTE" "$BRANCH"
REMOTE_HEAD="$(git -C "$ROOT" rev-parse "$REMOTE/$BRANCH")"
[ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] \
    || { echo "error: appcast commit did not reach $REMOTE/$BRANCH" >&2; exit 1; }

echo "Published: https://github.com/$REPO/releases/tag/v$VERSION"
echo "Update feed committed and pushed: $(plist SUFeedURL)"
