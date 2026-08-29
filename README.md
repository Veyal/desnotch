# desnotch

Lightweight native macOS notch app for media, local coding-agent activity, and other ambient
system status.

desnotch keeps a compact pill visible at the top of the screen and expands it on hover. It can
show system-wide now-playing artwork and transport controls, local Claude Code/Codex/Pi/OpenCode
activity, calendar glance, process and media-use status, battery changes, notification banners,
and a file tray. An opt-in clipboard pocket keeps up to eight recent plain-text copies in memory
only, and recognized Zoom/Teams/Meet/Webex-style calendar links open with one click.

The status-bar menu provides the keyboard and VoiceOver path for media transport, agent actions,
meeting links, tray and clipboard items, notification actions, privacy mode, display-awake mode,
settings, launch at login, and quit. See `AGENTS.md` for load-bearing privacy, geometry, and
runtime invariants.

## Running in development

Requires Xcode's command line tools (for `swift`) - no Xcode GUI project needed.

```sh
swift run
```

`swift build` also works standalone. `swift test` requires an XCTest-capable Xcode toolchain;
the GitHub Actions macOS runner is the authoritative test environment for this machine, whose
Command Line Tools installation does not include XCTest.

The app has no dock icon (`LSUIElement`/accessory activation policy). A menu bar status item
provides a reliable Quit and a Launch-at-Login toggle (the notch panel itself can't become the
key window, so the app menu's Cmd+Q isn't always reachable). `pkill desnotch` is also safe -
SIGTERM/SIGINT are handled and clean up the perl adapter subprocess instead of orphaning it.

## Building the distributable `.app`

```sh
scripts/build-app.sh
```

This runs `swift build -c release`, bundles the host-architecture binary into `dist/desnotch.app`
with a minimal `Info.plist` (version from the latest git tag, or `VERSION=...`), places the
MediaRemote adapter under `Contents/Resources/MediaRemoteAdapter`, validates version/build
metadata and required resources, then ad-hoc codesigns it inside-out (no `--deep`, so each
component has its own signature). The current host build remains the default. For a validated
arm64+x86_64 executable, opt in with `UNIVERSAL=1 scripts/build-app.sh`; it cross-builds both
targets and lipo-merges them (the adapter is already universal). A stable reverse-DNS bundle ID
can be selected with `BUNDLE_ID=com.example.desnotch`. For external distribution, provide a
Developer ID identity and hardened runtime explicitly:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
HARDENED_RUNTIME=1 scripts/build-app.sh
```

Notarization is also opt-in and uses a preconfigured notarytool keychain profile; credentials
are never stored in the repository:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" HARDENED_RUNTIME=1 \
NOTARIZE=1 NOTARY_PROFILE=desnotch-notary scripts/build-app.sh
```

External distribution is pending the owner's Developer ID/notary credentials. Gatekeeper may warn
on other machines; right-click > Open (or `xattr -dr com.apple.quarantine dist/desnotch.app`) to
run it anyway. Drag `dist/desnotch.app` to `/Applications`, or run it directly with
`open dist/desnotch.app`.

## How it works

- **Now-playing data & control**: via the private `MediaRemote.framework`, since there is no
  public API for system-wide now-playing state. As of macOS 15.4, Apple entitlement-gated the
  relevant call, so the app uses the vendored adapter subprocess described in
  `Sources/DesnotchCore/MediaRemote/Vendor/MediaRemoteAdapter/NOTICE.md`. Packaged apps resolve
  it from `Contents/Resources/MediaRemoteAdapter`; `swift run` uses the SwiftPM resource.
  Updates stay notification/stream-driven, never polled, so idle CPU stays near zero.
- **Notification mirror**: optional and off by default. It uses an Accessibility observer for
  notification banners, keeps banner content in memory only, and does not scrape the notification
  database.
- **Clipboard pocket**: optional and off by default. It polls only the pasteboard change counter,
  stores at most eight bounded plain-text items in memory, skips concealed/transient password-
  manager copies, clears immediately when disabled or when the app exits, and redacts previews
  while Privacy Mode is enabled.
- **Calendar join**: EventKit supplies the next event. Only recognized HTTP(S) conferencing hosts
  become a Join action; event notes and locations are inspected transiently and never displayed or
  persisted.
- **Notch geometry**: on a MacBook with a physical notch, the pill is sized and positioned
  using `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` to hug
  the actual notch cutout. On a screen with no notch (this project was developed on a
  Mac mini, which has none), it renders the same wings-around-cutout layout around a synthetic
  MacBook-sized notch at the top center of the screen.

See `AGENTS.md` for implementation details load-bearing for anyone continuing this project.

## Current Boundaries

- **Real notch geometry is untested on this dev machine.** This project was developed on a
  Mac mini, which has no physical notch, so notch-hugging geometry only ever exercised the
  fallback path here. Final animation/geometry polish against a *real* notch cutout should
  happen on an actual notched MacBook.
- Notification mirroring is Accessibility- and macOS-version-dependent.
- Distribution signing and notarization require the explicit opt-in configuration described above.
- Accessibility has no standard Info.plist usage-description key. Enable it for notification
  mirroring in System Settings → Privacy & Security → Accessibility; the app documents and
  rechecks that grant. Calendar uses the standard usage-description keys.
- Universal builds and external signing/notarization are explicit opt-ins. The default host build
  is intentionally retained, and real-notch/Intel runtime verification remains hardware-gated.

## Packaging smoke checks

CI runs `scripts/smoke-test.sh` after packaging. Locally, use `scripts/smoke-test.sh` to validate
plist keys, icon and adapter resources, executable architecture, strict nested signatures, and
obvious orphaned adapter processes. `scripts/runtime-smoke-test.sh` launches the packaged binary
in non-interactive smoke mode, verifies the adapter starts, sends SIGTERM, and proves both owned
processes exit. `scripts/permission-status.sh` prints a non-prompting Accessibility and Calendar
authorization snapshot. Because macOS may attribute a shell-launched Accessibility check to the
responsible parent process, treat `trusted` as diagnostic and verify the normally launched app
before relying on `REQUIRE_GRANTED=1`; the script documents this caveat beside the check.
`MANUAL=1 scripts/smoke-test.sh` prints the interactive permission/media/menu/termination/notch/
Intel checklist; those checks require a desktop session and appropriate hardware.
