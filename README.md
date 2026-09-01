# DexBar

DexBar is a small, native macOS menu-bar app that shows the OpenAI Codex usage available to the ChatGPT account already signed in through Codex.

It is built with SwiftUI and AppKit, has no web view, and does not appear in the Dock. The normal menu-bar display is deliberately quiet: it shows the weekly allowance, while a shorter window such as a five-hour cap appears only after Codex reports that window as active or reached.

![DexBar showing the minimal weekly view](Docs/DexBar-current.png)

## What it shows

- Weekly usage, percentage used, time until reset, and the exact reset date.
- A weekly projection after one day of history, plus a quiet short-window projection after one hour when it is heading to at least 60%.
- Active shorter windows and urgent model-specific limits only when they matter.
- An optional global shortcut to show or hide the popover from any app, configurable in Menu Bar Settings.
- Optional notifications at 80%, 95%, and when the weekly projection crosses 100%.
- Connection, stale-data, and sign-in states without replacing the last known value unnecessarily.

## Privacy

DexBar starts the installed Codex CLI's local app server and asks it for account rate limits. It reuses the Codex sign-in but does not read or copy Codex credentials into its own files. It stores only usage percentages, timestamps, and reset dates for projection. It never sends a prompt to check usage.

The optional global shortcut uses macOS's Carbon hotkey registration. It receives only the chosen combination and does not require Accessibility permission. The shortcut ships disabled and unbound so DexBar does not claim a system-wide key combination without being asked.

## Requirements

- macOS 14 or later.
- Apple silicon.
- Codex CLI installed and signed in with ChatGPT.

## Build

```sh
swift test
SIGN=0 ./Scripts/build.sh
```

The app bundle is written to `dist/DexBar.app`. Local builds use `SIGN=0`; the default release build finds a Developer ID Application identity and applies a hardened-runtime, timestamped signature.

## Releasing

DexBar follows the same guarded release path as ClawBar:

```sh
./Scripts/build.sh       # Developer ID signing
./Scripts/notarize.sh    # notarise and staple the app and DMG
./Scripts/release.sh     # verify source/artifact/remote identity; stage assets
PUBLISH=1 ./Scripts/release.sh
```

Copy `.env.example` to `.env` first and provide an App Store Connect API key. The release guard refuses dirty source, duplicate versions, mismatched Git-derived build numbers, unpushed commits, unsigned artifacts, and unstapled artifacts. Published releases include a versioned DMG, a stable latest-download DMG, and a SHA-256 checksum.

Version 0.1 uses GitHub Releases for updates; DexBar does not silently install updates.

## Project layout

- `Sources/DexBarCore` contains the Codex app-server client, response mapping, formatting, and projection logic.
- `Sources/DexBar` contains the AppKit lifecycle and menu-bar plumbing plus SwiftUI views.
- `Tests/DexBarCoreTests` covers window visibility, health thresholds, weekly and short-window projection, and formatting.
- `Scripts/build.sh` assembles the standalone `.app` bundle.

DexBar is an independent, unofficial tool. It is not made or endorsed by OpenAI.

## Licence

MIT — see [LICENSE](LICENSE).
