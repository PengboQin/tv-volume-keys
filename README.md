# TV Volume Keys

[简体中文](README.zh-CN.md)

A free, local macOS menu-bar utility that sends your keyboard's volume and mute
keys to a compatible HDMI TV over CEC. No account, audio driver, server, or network
debugging is needed. MIT licensed.

**Status: experimental preview. The binary is ad-hoc signed and is not notarized.**

## Compatibility

- Apple silicon and a compatible HDMI-CEC connection.
- One external screen; default audio output must use HDMI.
- Built for macOS 14 or later. Only macOS 27.0.1 on an M4 Mac mini with one
  FFalcon 65S585C Pro has real-device evidence so far. Older OS versions,
  other Macs, TVs, receivers, docks, and adapters remain unverified.
- The app detects the CEC tunnel rather than relying on a TV brand name.
- Ordinary apps using the same TV sound output do not require plug-ins.
  Per-app audio routing and the external sound system can affect what you hear.

This is not a universal sound mixer. It changes the TV's hardware volume setting.
It does not replace the macOS HDMI volume slider or control an optical receiver
directly. The CEC bridge uses non-public IOKit entry points and may need changes
after macOS updates. See [compatibility and distribution](docs/兼容与分发.md).

## Download

Use the [Releases page](https://github.com/PengboQin/tv-volume-keys/releases) for preview downloads, source and checksums.
If macOS refuses the unnotarized preview, build from source or wait for a
notarized release. Do not disable Gatekeeper.

## Build locally

Requires Xcode command-line tools and Python 3. There are no package downloads.

```sh
python3 scripts/build.py --dry-run
python3 scripts/build.py --package
```

The app is built in `.build/`; the local-preview DMG, source ZIP, checksums, and
validation result are written to `dist/`. Local validation includes connection
state and is not part of public release assets. Builds are arm64 with an explicit
macOS 14 deployment target, and use ad-hoc signing, not Developer ID notarization.
This script does not install, launch, or publish the app.

## Use

Move the app to Applications and open it. Inspect its connection status in the
`TV` menu. Enable CEC on your TV and select HDMI as the Mac sound output. Choose
**Allow Keyboard Control** and approve the app in macOS Accessibility settings.
Use volume/mute keys, holding Fn if your top row is configured as function keys.

The menu also provides volume controls, pause, Open at Login, and Quit. Login
startup is off by default and uses macOS ServiceManagement when enabled.
Option/Command/Control media-key shortcuts stay with macOS. Long presses do not
accumulate a delayed queue; mute does not repeat while held.

The local preview refuses to start alongside the earlier household helper.
Keep the existing working app unless you intentionally choose to test this one.

## Privacy and sharing

Only system media-key events are subscribed to; ordinary typed text is not
recorded. A small local status file records permission, connection state, and
volume-command counts. Nothing is uploaded. Support reports should be reviewed
before sharing.

Source is available under the MIT license. This preview has not completed
Developer ID signing or Apple notarization; those distribution checks are
separate from functional testing. The earlier household helper has real volume-key
acceptance, while this packaged preview has build, routing and read-only connection
checks; its separate GUI/permission flow and other hardware remain unverified.

Acknowledgements and the upstream MIT notice are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
