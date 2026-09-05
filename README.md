# DexBar

![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-brightgreen)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M1%2B-black?logo=apple&logoColor=white)
![Notarised](https://img.shields.io/badge/Notarised-Developer%20ID-success)
[![Latest release](https://img.shields.io/github/v/release/vmlrodrigues/DexBar?label=latest)](https://github.com/vmlrodrigues/DexBar/releases/latest)

[![Download for Mac](https://img.shields.io/badge/Download_for_Mac-007AFF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/vmlrodrigues/DexBar/releases/latest/download/DexBar.dmg)

DexBar is a small, native macOS menu-bar app that shows the OpenAI Codex usage available to the ChatGPT account already signed in through Codex.

It is built with SwiftUI and AppKit, has no web view, and does not appear in the Dock. The normal menu-bar display is deliberately quiet: it shows the weekly allowance, while a shorter window such as a five-hour cap appears only after Codex reports that window as active or reached.

![DexBar showing the minimal weekly view](Docs/DexBar-current.png)

## What it shows

- Weekly usage, percentage used, time until reset, and the exact reset date.
- An adaptive weekly projection after one day of history, plus a quiet short-window projection after one hour when it is heading to at least 60%.
- The ChatGPT plan and Codex default service mode when the local app server reports them.
- Active shorter windows and urgent model-specific limits only when they matter.
- An optional global shortcut to show or hide the popover from any app, configurable in Menu Bar Settings.
- Optional notifications at 80%, 95%, and when the weekly projection crosses 100%.
- Connection, stale-data, and sign-in states without replacing the last known value unnecessarily.
- The exact app version and build number in the popover footer.

## Privacy

DexBar starts the installed Codex CLI's local app server and asks it for account rate limits and the effective default service mode. It reuses the Codex sign-in but does not read or copy Codex credentials into its own files. It stores only usage percentages, timestamps, and reset dates for projection. Service mode is display-only and is not written to projection history. DexBar never sends a prompt to check usage.

The optional global shortcut uses macOS's Carbon hotkey registration. It receives only the chosen combination and does not require Accessibility permission. The shortcut ships disabled and unbound so DexBar does not claim a system-wide key combination without being asked.

## Requirements

- macOS 14 or later.
- Apple silicon.
- Codex CLI installed and signed in with ChatGPT.

## Install

1. [Download DexBar.dmg](https://github.com/vmlrodrigues/DexBar/releases/latest/download/DexBar.dmg).
2. Open the disk image and drag DexBar to Applications.
3. Launch DexBar. It will use the ChatGPT account already signed in through the Codex CLI.

DexBar checks for updates once per day and prompts before installing them. You can also
check immediately from **Settings → General → Software updates**. Update downloads are
verified with a DexBar-specific EdDSA signature and Apple's code signature before they are
installed.

## Build

```sh
swift test
./Scripts/build.sh
```

The app bundle is written to `dist/DexBar.app`. A normal invocation creates an ad-hoc-signed
development build: its menu-bar symbol is a hammer, automatic updates and login-item changes
are disabled, and the About pane identifies it as Development. The build script refuses to
replace that bundle while it is running.

A release build is deliberately explicit and requires clean, committed source:

```sh
BUILD_CHANNEL=release SIGN=1 ./Scripts/build.sh
```

The release build finds a Developer ID Application identity and applies a hardened-runtime,
timestamped signature. Its exact Git revision is embedded in the application for release
provenance; unknown build-channel metadata always fails closed as development behavior.

## Releasing

DexBar follows the same guarded release path as ClawBar:

```sh
BUILD_CHANNEL=release SIGN=1 ./Scripts/build.sh  # clean Developer ID release build
./Scripts/notarize.sh    # notarise and staple the app and DMG
./Scripts/release.sh     # verify, sign the update, and stage release assets/appcast
PUBLISH=1 ./Scripts/release.sh  # publish the GitHub release and update appcast.xml
```

Store validated notarization credentials in the macOS Keychain once:

```sh
xcrun notarytool store-credentials PersonalProjectsNotary --sync
```

The release scripts use that shared profile by default; set `NOTARY_KEYCHAIN_PROFILE` only
when deliberately using another validated profile. No App Store Connect private key or
issuer metadata is copied into the repository. The release guard refuses dirty source,
development-channel builds, a source-revision mismatch, mismatched Git-derived build
numbers, unpushed commits, unsigned artifacts, and unstapled artifacts. Published releases
include a versioned DMG, a stable latest-download DMG, and a SHA-256 checksum.

The release is published before the script commits and pushes `appcast.xml`, so Sparkle
never sees an enclosure URL that still returns 404. Publication succeeds only after the
appcast commit is verified on the remote branch. The feed points Sparkle at the versioned,
notarised GitHub release asset.

Publication is resumable. If GitHub accepted the release but the local appcast commit or push
failed, rerunning the publish command verifies the existing tag and every downloaded asset
against the exact candidate before completing the feed publication.

## Project layout

- `Sources/DexBarCore` contains the Codex app-server client, response mapping, formatting, and projection logic.
- `Sources/DexBar` contains the AppKit lifecycle and menu-bar plumbing plus SwiftUI views.
- `Tests/DexBarCoreTests` covers window visibility, health thresholds, build-channel policy, adaptive and short-window projection, service-mode mapping, and formatting.
- `Scripts/build.sh` assembles the standalone `.app` bundle.

DexBar is an independent, unofficial tool. It is not made or endorsed by OpenAI.

## Licence

MIT — see [LICENSE](LICENSE). Sparkle's complete licence and bundled third-party notices
are retained in [Resources/ThirdPartyLicenses/Sparkle-LICENSE.txt](Resources/ThirdPartyLicenses/Sparkle-LICENSE.txt)
and included in the application bundle.
