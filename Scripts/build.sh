#!/usr/bin/env bash
# Builds DexBar.app. Local builds are development-channel and ad-hoc signed by default;
# release behavior and Developer ID signing must both be requested explicitly.
#
#   ./Scripts/build.sh                              local development build
#   SIGN=1 ./Scripts/build.sh                       Developer ID-signed development build
#   BUILD_CHANNEL=release SIGN=1 ./Scripts/build.sh release build
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

SIGN="${SIGN:-0}"
[[ "$SIGN" = "0" || "$SIGN" = "1" ]] || { echo "error: SIGN must be 0 or 1" >&2; exit 1; }
BUILD_CHANNEL="${BUILD_CHANNEL:-development}"
[[ "$BUILD_CHANNEL" = "development" || "$BUILD_CHANNEL" = "release" ]] \
    || { echo "error: BUILD_CHANNEL must be development or release" >&2; exit 1; }
[ "$BUILD_CHANNEL" != "release" ] || [ "$SIGN" = "1" ] \
    || { echo "error: release builds require SIGN=1" >&2; exit 1; }

SOURCE_REVISION="${SOURCE_REVISION:-}"
if [ -z "$SOURCE_REVISION" ]; then
    if SOURCE_REVISION="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
        if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]; then
            SOURCE_REVISION="$SOURCE_REVISION-dirty"
        fi
    else
        SOURCE_REVISION="unknown"
    fi
fi
[[ "$SOURCE_REVISION" = "unknown" || "$SOURCE_REVISION" =~ ^[0-9a-f]{40,64}(-dirty)?$ ]] \
    || { echo "error: invalid SOURCE_REVISION '$SOURCE_REVISION'" >&2; exit 1; }

if [ "$BUILD_CHANNEL" = "release" ]; then
    [ "$SOURCE_REVISION" != "unknown" ] && [[ "$SOURCE_REVISION" != *-dirty ]] \
        || { echo "error: release builds require clean, committed source" >&2; exit 1; }
fi

RUNNING_PID=""
PIDS=""
if PIDS="$(pgrep -x "$APP_NAME" 2>/dev/null)"; then
    :
else
    PGREP_STATUS="$?"
    # pgrep returns 1 when there are simply no matches. Any other failure means the
    # process list could not be inspected, so replacing the bundle would be unsafe.
    [ "$PGREP_STATUS" = "1" ] || {
        echo "error: unable to inspect running $APP_NAME processes" >&2
        exit 1
    }
fi
while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    PROCESS_COMMAND="$(ps -ww -p "$pid" -o command= 2>/dev/null)" || {
        echo "error: unable to inspect $APP_NAME process $pid" >&2
        exit 1
    }
    if [ "$PROCESS_COMMAND" = "$APP/Contents/MacOS/$APP_NAME" ] \
        || [[ "$PROCESS_COMMAND" = "$APP/Contents/MacOS/$APP_NAME "* ]]; then
        RUNNING_PID="$pid"
        break
    fi
done <<< "$PIDS"
[ -z "$RUNNING_PID" ] || {
    echo "error: $APP is running as pid $RUNNING_PID" >&2
    echo "       quit that development copy before rebuilding its bundle" >&2
    exit 1
}

echo "==> Building $APP_NAME $VERSION ($BUILD) [$BUILD_CHANNEL, $SOURCE_REVISION]"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/$APP_NAME"
[ -x "$BIN" ] || { echo "error: no binary at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    -e "s/__BUILD_CHANNEL__/$BUILD_CHANNEL/g" \
    -e "s/__SOURCE_REVISION__/$SOURCE_REVISION/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi

SPARKLE_LICENSE="$ROOT/Resources/ThirdPartyLicenses/Sparkle-LICENSE.txt"
[ -f "$SPARKLE_LICENSE" ] \
    || { echo "error: bundled Sparkle licence is missing: $SPARKLE_LICENSE" >&2; exit 1; }
cp "$SPARKLE_LICENSE" "$APP/Contents/Resources/"

# SwiftPM builds Sparkle but does not know how to place a dynamic framework inside the
# hand-assembled .app bundle. `ditto` preserves the framework's symlink structure.
SPARKLE_FW="$(find "$ROOT/.build/artifacts/sparkle" -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
if [ -n "$SPARKLE_FW" ]; then
    echo "==> Embedding Sparkle"
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
else
    echo "error: Sparkle.framework not found — run 'swift package resolve' first" >&2
    exit 1
fi

if [ "$SIGN" = "1" ]; then
    IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
    [ -n "$IDENTITY" ] || { echo "error: no Developer ID Application identity" >&2; exit 1; }

    # Sparkle contains independently signed nested executables. Re-sign them from the
    # inside out so the outer signatures cover their final bytes, preserving the XPC
    # services' shipped entitlements.
    FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    for xpc in Installer Downloader; do
        codesign --force --options runtime --timestamp \
                 --preserve-metadata=entitlements \
                 --sign "$IDENTITY" "$FW/XPCServices/$xpc.xpc"
    done
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Updater.app"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
             "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
    echo "==> Gatekeeper assessment (expected to fail until notarised):"
    spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true
else
    echo "==> Ad-hoc signing for local use"
    codesign --force --sign - "$APP"
fi

echo
echo "Built: $APP"
du -sh "$APP" | awk '{print "Size:  " $1}'
