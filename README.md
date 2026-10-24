# TV Volume Keys

[简体中文](README.zh-CN.md)

Free, open-source macOS menu-bar volume control for a TV connected to your Mac.
Choose native HDMI-CEC, or explicitly configure an ADB compatibility connection
for an Android TV when the CEC path is unavailable. No account, advertising,
telemetry, audio driver, or custom background server.

**0.2.0-preview.1 is an experimental preview.** Official release artifacts use
Developer ID signing; the release's `release-validation.json` reports the actual
notarization result. Local builds default to ad-hoc signing. Hardware support is
connection-specific, not a promise that every Mac or TV works.

## Requirements

- Apple silicon, macOS 14+, one external display, default sound output over HDMI.
- CEC: a compatible Mac/adapter/TV connection. An M4 Mac mini has real CEC volume-key evidence.
- ADB: an Android TV with network debugging, official Android Platform Tools already
  installed on your Mac, the TV's private IPv4 address and port, and TV authorization.
  The app does not download adb, scan your network, enable TV debugging, or open ports.
- This M1 test connection had no usable CEC address. Its ADB volume interface was
  verified; see [the device-validation record](docs/M1验证与ADB通道.md).

This changes the TV's volume setting, not macOS's disabled HDMI slider or an optical
speaker's own hardware volume. Per-app output and external audio equipment may
still affect what you hear. The CEC path uses non-public IOKit interfaces.

## Download and use

Download from [Releases](https://github.com/PengboQin/tv-volume-keys/releases), verify
`SHA256SUMS`, and move **TV Volume Keys Preview.app** into Applications. Do not disable
Gatekeeper. Keep a working previous version until your own setup is verified.

1. Select the HDMI TV as your Mac's sound output and open the app's **TV** menu.
2. For CEC, leave **HDMI-CEC (Default)** selected and enable the TV's CEC feature.
3. For ADB, use **Configure ADB Connection…**. Enter your own private IPv4 and port
   (example: `192.168.1.50:5555`) and the absolute path to your official `adb` executable.
   Approve the Mac on the TV if prompted. Verify and Use ADB binds the configuration
   to that TV's identity. Use the menu to switch back to CEC at any time.
4. Choose **Allow Keyboard Control…**, then enable this app in macOS Accessibility.
   An update that changes signing identity may require user reauthorization.
5. Use volume/mute keys; hold Fn if your keyboard uses standard function keys.

If Accessibility appears enabled but the app still reports missing permission after
an upgrade, remove its stale Accessibility entry and add the current **TV Volume
Keys Preview.app** from Applications again. Enable that entry; do not reset other
apps' permissions or disable system protection. This recovered the tested M1
installation, whose physical keyboard control was then confirmed by the user.
See the [installation and permission record](docs/M1安装与权限恢复.md).

Menu buttons work through the same selected transport. Pause, Quit and optional
Open at Login are included; installation does not silently enable a login item.
Option/Command/Control media shortcuts pass through to macOS. Headphone output or
an ambiguous display connection does not capture volume keys. Busy repeats are
dropped rather than queued after release. Held mute does not repeatedly toggle.

ADB is explicitly selected, never an automatic failover to a guessed TV. Each
command verifies device identity and pins the live ADB transport; a changed target
is rejected. Disconnected or unauthorized devices show an error and require recovery,
without automatic volume retries. ADB mute uses the TV's volume-mute key, while
up/down use the supported media-volume interface; other TV firmware needs validation.

## Build

Existing Xcode command-line tools and Python 3 are required. No package downloads:

```sh
python3 scripts/build.py --dry-run
python3 scripts/build.py --package
# Optional: --sign-identity 'your Developer ID Application identity'
```

The build compiles arm64/macOS14, runs host-only routing and transport checks,
verifies signing and produces a DMG, source ZIP and validation in `dist/`. Packaging
requires committed inputs in a Git checkout. It does not install, launch, notarize,
or publish automatically. `.build/` and `dist/validation-local.json` may contain
local diagnostics and must not be published. Public release checksums are recomputed
after signing/notarization/stapling.

For explicit automation, the app executable supports `--diagnose` (read-only),
`--configure-adb PRIVATE_IP:PORT --adb-path /absolute/path/to/adb` and `--use-cec`.
Quit and reopen a running GUI after CLI configuration. `--send up|down|mute` really
controls the selected TV and is for authorized verification only. No arbitrary
remote shell interface is exposed.

## Privacy and boundaries

Only media-key events are observed; ordinary text is not recorded. A small local
status file contains permission/readiness and command counts. ADB connection details
and a hash of TV identity are stored in an owner-only local file, never the app,
release or public diagnostics. Existing ADB keys remain managed by official adb;
the app does not read/export them. Nothing is uploaded by the application.

ADB grants much broader access than this app's volume-only commands. Use a trusted
LAN, never expose debugging to the Internet, and revoke unfamiliar computer access.
It is not a minimum-permission TV protocol. No source, display, audio-route, power,
VPN, firmware or system-package changes are part of this utility.

Source is MIT licensed. See [compatibility](docs/兼容与分发.md) and
[upstream acknowledgement](THIRD_PARTY_NOTICES.md). Host checks, signing, installation,
keyboard-event delivery and the user's actual listening experience are separate
validation steps; a compiled preview is not universal compatibility.
