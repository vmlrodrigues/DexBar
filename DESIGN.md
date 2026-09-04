# DexBar design

## Product rule

The app answers one question at a glance: “How much of my useful Codex allowance remains?” The weekly window is the stable default. Extra meters are conditional information, not permanent furniture.

## Window visibility

1. Choose the longest general Codex window as the weekly baseline.
2. Hide zero-valued or otherwise inactive secondary windows.
3. Show an active shorter window immediately, with its model name when provided.
4. Keep parallel long model-specific windows hidden until they reach 80%.
5. Surface the most urgent visible window in the menu bar; otherwise keep the menu bar on weekly usage.

This rule is based on the limits Codex returns rather than assuming every account has a five-hour window.

## Interface

- AppKit owns the `NSStatusItem`, `NSPopover`, and settings/onboarding windows.
- SwiftUI renders the popover, settings, onboarding, meters, state messages, and reusable controls.
- The app is an `LSUIElement`, so it has no Dock icon or normal app menu presence.
- The menu bar uses a compact monochrome calendar mark plus percentage and/or reset time.
- Green/neutral is normal, orange starts at 80%, and red starts at 95%.
- Usage meters are 10 points high, matching ClawBar and standard macOS storage/battery-style meters rather than reading as hairlines.
- Popover icon controls are pointer-only: they remain accessibility actions but are removed from the Tab loop and do not draw keyboard focus plates.

## Global shortcut

DexBar can show or hide the popover from any app using `RegisterEventHotKey`. This is the same permission-free Carbon path used by ClawBar; it does not install a global keyboard monitor or request Accessibility access. Recording uses a local event monitor only while DexBar's Settings window is key.

The shortcut ships disabled and unbound. Settings requires Control or Option in the combination, preventing a global Command-only binding from overriding the frontmost app's ordinary menu shortcuts. Registration failures are visible rather than silently accepting a combination already owned by another app.

When the shortcut opens the popover, DexBar activates first because an accessory app is not brought forward implicitly by a global hotkey. Closing does not activate, avoiding an unnecessary focus steal.

## Software updates

DexBar uses Sparkle 2.9.5. `SUEnableAutomaticChecks` and an 86,400-second interval make it
check the public appcast once per day. `SUAutomaticallyUpdate` is deliberately absent:
Sparkle presents the available update and the user chooses when to install it. Settings
also exposes a manual **Check Now** action without adding another sidebar destination.

The appcast lives in the public GitHub repository and every versioned DMG is signed with a
DexBar-specific EdDSA key. The private key lives only in the developer's login Keychain;
the public key is baked into `Info.plist`. Losing or changing that private key would prevent
already-installed copies from accepting future releases.

SwiftPM does not assemble an app bundle, so the build script embeds `Sparkle.framework`
and signs its nested XPC services and helper executables from the inside out before signing
DexBar. The updater's UI delegate activates the dockless app before Sparkle presents a
modal alert, preventing scheduled-update UI from appearing behind another application.

The release script stages a candidate appcast alongside the signed release assets and
refuses to sign it unless the selected Keychain account derives the public key embedded in
the app. On an explicit publish it creates the GitHub release first, then commits and pushes
the repository appcast and verifies that commit on the remote branch. This ordering prevents
installed copies from being offered a download URL that is not live yet.

## Data flow

```text
Codex CLI app-server
        │ account/rateLimits/read + config/read
        ▼
response mapper ──► visibility rules ──► AppModel ──► status item + popover
                                              │
                                              └──► local projection history
```

Each read uses a fresh short-lived app-server process and performs the documented initialize handshake. Refreshing is adaptive: opening the popover, waking the Mac, or recent Codex activity refreshes quickly; idle checks back off.

The session-folder activity watcher is only a refresh hint. It is never treated as an authority for usage and its failure cannot corrupt the displayed limits.

## Projection

The weekly estimator combines two measured paces: the average since the current counter began and a recency-weighted linear trend over the latest 24 hours. Recent observations are sampled into fixed hourly buckets so rapid polling cannot dominate the fit, and their weight decays with a 12-hour half-life. The recent trend is admitted only after at least six hours and three whole percentage points of evidence. Its share then rises smoothly from 25% toward a 75% cap as span and movement grow. This makes a real change in working intensity visible without allowing a single one-point update to replace the estimator's anchor.

The tooltip discloses both paces and a conservative reset-date range. The range spans the long and recent outcomes, then adds a whole-point measurement margin that grows when little of the window has elapsed. This prevents a rounded estimate near 100% from being labelled confidently safe. It replaces ClawBar's fixed `1.5 × days remaining` margin, which was calibrated on a different provider and was not evidence for OpenAI usage. The visible marker remains one blended value.

Weekly projection starts after 24 hours of observations. Short-window projection starts after one hour but remains invisible below a projected 60%, because five-hour usage is commonly front-loaded and a low estimate is unactionable furniture. Unchanged samples are retained at most hourly, samples expire after eight days, reset timestamps tolerate one minute of server jitter, reset changes naturally start a new baseline, and the user can clear history in Settings. A failed refresh freezes the projection at the last successful snapshot time instead of letting stale data drift forward.

The projected extent is drawn beneath current usage as a translucent continuation. An anchored marker labels projections up to 100%; off-scale projections replace the false 100% endpoint with one to three chevrons and a right-aligned value.

## Failure behaviour

- A temporary refresh failure retains the last successful snapshot and marks it stale.
- Missing Codex CLI and expired sign-in have dedicated recovery copy.
- Unknown or newly introduced limit buckets are handled by duration and activity rather than a fixed list of model names.
