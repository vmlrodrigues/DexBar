# Verification

Verification updated on 4 September 2026.

## Automated checks

- Debug and release Swift builds complete successfully.
- All twenty-four core tests pass.
- A live Codex app-server probe returns the signed-in ChatGPT plan, effective default service mode, and usage windows.
- The current live response maps the seven-day general limit to the weekly display.
- The current zero-valued five-hour bucket is filtered out.
- Synthetic tests confirm that an active or reached five-hour bucket appears, and that a quiet model-specific weekly bucket stays hidden until warning level.
- Projection tests cover the 24-hour weekly minimum, hourly-sampled weighted regression, a bounded one-point update, conservative near-limit ranges, legacy-history decoding, hourly heartbeat compaction, one-hour short-window minimum, the 60% short-window display threshold, and one-minute reset-date jitter.
- Notification tests verify raw 80%/95% crossings, persisted relaunch latches, reset timestamp jitter, window rollover, and projection rearming.
- App-server fixtures verify service-mode normalization, config errors, response ordering, and that optional config metadata can never delay a valid usage result. A hostile fixture that floods stderr and ignores termination is force-killed within the configured deadline.
- Carbon global-hotkey support and its local shortcut recorder compile without adding an Accessibility entitlement or permission prompt.
- The non-visual shortcut self-check successfully registers and releases a temporary Carbon hotkey through the production registration path.
- Sparkle 2.9.5 resolves and links through the packaged app's Frameworks rpath.
- The packaged Info.plist enables automatic checks at an 86,400-second interval, points at the public DexBar appcast, and contains the matching DexBar EdDSA public key.
- The DexBar-specific private key was read back from the login Keychain through Sparkle's public-key command and successfully signed an existing disk image.
- The release guard compares that Keychain account's public key with `SUPublicEDKey` before signing an update.
- The appcast generator produces valid XML and an idempotent signed release entry; all release shell scripts pass syntax checking.
- Sparkle's complete licence and bundled third-party notices are retained in source and copied into the application bundle.
- A Developer ID build signs Sparkle's Installer and Downloader XPC services, Autoupdate helper, Updater app, framework, and DexBar in inside-out order; strict deep signature validation passes.
- Static renders were inspected in current, active-window, warning, critical, stale, authentication, dark-mode, onboarding, and settings states.
- The packaged app ran hidden at 0.0% sampled CPU and a 26 MB `phys_footprint` (27 MB peak) after its first refresh.

## Manual acceptance checks

- Menu bar: compact, legible, template-compatible status symbol.
- Default popover: only the weekly meter is visible when no other window is relevant.
- Conditional popover: active five-hour meter is clearly separated and labelled with the returned model name.
- Meter: 10-point height and projection treatment visually match ClawBar's rendered reference, including the landing marker and off-scale chevrons.
- Popover buttons: explicitly excluded from keyboard focus and focus-effect rendering while retaining native button accessibility actions.
- Menu Bar Settings: shortcut enablement, recorder, clear action, registration status, and permission explanation fit without clipping.
- Settings: native semantic typography and all controls fit without clipping in the 620 × 420 window.
- General Settings: the compact Software updates row fits without clipping and states the daily, confirmation-before-install behaviour.
- Onboarding: explains the existing Codex sign-in and local history before enabling alerts.

The native hidden-launch check confirmed that the packaged process stayed responsive and exposed only hidden window-server surfaces. Offsider pixel capture and accessibility inspection were unavailable because the host had not granted those permissions and its display was asleep; visual verification therefore used DexBar's own offscreen renderer.

## Release notes

`Scripts/build.sh`, `Scripts/notarize.sh`, and `Scripts/release.sh` provide Developer ID signing (including Sparkle's nested services), two-stage notarisation and stapling, DMG packaging, Gatekeeper assessment, EdDSA update signing, appcast generation, source/build/remote identity checks, and explicit GitHub publication. A public candidate must pass that complete path; `SIGN=0` output remains local-only. The generated appcast is committed only after its corresponding GitHub release exists, pushed automatically, and verified on the remote branch before publication reports success.
