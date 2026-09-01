# Verification

Verification completed on 31 August 2026.

## Automated checks

- Debug and release Swift builds complete successfully.
- All nine core tests pass.
- A live Codex app-server probe returns the signed-in ChatGPT plan and usage windows.
- The current live response maps the seven-day general limit to the weekly display.
- The current zero-valued five-hour bucket is filtered out.
- Synthetic tests confirm that an active or reached five-hour bucket appears, and that a quiet model-specific weekly bucket stays hidden until warning level.
- Projection tests cover the 24-hour weekly minimum, one-hour short-window minimum, 60% short-window display threshold, measured rate, horizon uncertainty, and reset date matching.
- Carbon global-hotkey support and its local shortcut recorder compile without adding an Accessibility entitlement or permission prompt.
- The non-visual shortcut self-check successfully registers and releases a temporary Carbon hotkey through the production registration path.
- Static renders were inspected in current, active-window, warning, critical, stale, authentication, dark-mode, onboarding, and settings states.
- The packaged app ran hidden at 0.0% sampled CPU and a 26 MB `phys_footprint` (27 MB peak) after its first refresh.

## Manual acceptance checks

- Menu bar: compact, legible, template-compatible status symbol.
- Default popover: only the weekly meter is visible when no other window is relevant.
- Conditional popover: active five-hour meter is clearly separated and labelled with the returned model name.
- Meter: 10-point height and projection treatment visually match ClawBar's rendered reference, including the landing marker and off-scale chevrons.
- Popover buttons: explicitly excluded from keyboard focus and focus-effect rendering while retaining native button accessibility actions.
- Menu Bar Settings: shortcut enablement, recorder, clear action, registration status, and permission explanation fit without clipping.
- Settings: native semantic typography and all controls fit without clipping in the 600 × 410 window.
- Onboarding: explains the existing Codex sign-in and local history before enabling alerts.

The native hidden-launch check confirmed that the packaged process stayed responsive and exposed only hidden window-server surfaces. Offsider pixel capture and accessibility inspection were unavailable because the host had not granted those permissions and its display was asleep; visual verification therefore used DexBar's own offscreen renderer.

## Release notes

The output is a locally ad-hoc-signed application. Distribution outside this Mac will require a Developer ID signature and notarization.
