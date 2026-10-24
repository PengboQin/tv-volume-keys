# Changelog

## 0.2.0-preview.1

- Explicit ADB compatibility mode alongside the default HDMI-CEC path, with a local connection dialog and TV identity binding.
- Faster supported Android media-volume adjustment; separate volume-mute key handling.
- Verified live-transport targeting, bounded subprocesses, asynchronous connection checks and no queued volume retries.
- Preserve single HDMI output, headphone/modifier pass-through and held-mute safeguards.
- Split transport, configuration UI and shared routing for maintenance; add host checks for target validation, identity mismatch and timeouts.
- Developer ID release signing support, source fingerprint metadata and updated setup/privacy documentation. Actual notarization and device acceptance are recorded separately in the release validation.

## 0.1.0-preview.1

First experimental source and binary preview.

- Volume up/down and mute through native HDMI-CEC.
- Menu-bar controls, pause, Accessibility permission entry and optional login startup.
- One external HDMI display and Apple silicon runtime checks.
- Modified media shortcuts pass through; held mute does not keep toggling; delayed volume repeats are dropped.
- English and Simplified Chinese labels, MIT license and MacTV acknowledgement.

The preview is not notarized. Build/routing/read-only checks do not replace testing the GUI permission flow or different hardware. The previous household helper's successful volume-key use is separate evidence.
