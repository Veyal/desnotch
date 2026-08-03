# desnotch

Lightweight native macOS notch app for media, local coding-agent activity, and other ambient
system status.

desnotch keeps a compact pill visible at the top of the screen and expands it on hover. It can
show system-wide now-playing artwork and transport controls, local Claude Code/Codex/Pi/OpenCode
activity, calendar glance, process and media-use status, battery changes, notification banners,
and a file tray.

The status-bar menu provides the keyboard and VoiceOver path for media transport, agent actions,
tray items, notification actions, privacy mode, settings, launch at login, and quit. See
`AGENTS.md` for load-bearing privacy, geometry, and runtime invariants.

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
with a minimal `Info.plist` (version from the latest git tag), places the MediaRemote adapter
under `Contents/Resources/MediaRemoteAdapter`, and ad-hoc codesigns it inside-out (no `--deep`,
so each component has its own signature). The current development host produces an arm64 app;
the universal adapter does not make the application universal. No notarization is attempted, so
Gatekeeper will warn on other machines; right-click > Open (or
`xattr -dr com.apple.quarantine dist/desnotch.app`) to run it anyway. Drag `dist/desnotch.app`
to `/Applications`, or run it directly with `open dist/desnotch.app`.

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
- **Notch geometry**: on a MacBook with a physical notch, the pill is sized and positioned
  using `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` to hug
  the actual notch cutout. On a screen with no notch (this project was developed on a
  Mac mini, which has none), it falls back to a fixed-width capsule floating top-center of
  the screen, in the same location a notch would occupy.

See `AGENTS.md` for implementation details load-bearing for anyone continuing this project.

## Current Boundaries

- **Real notch geometry is untested on this dev machine.** This project was developed on a
  Mac mini, which has no physical notch, so notch-hugging geometry only ever exercised the
  fallback path here. Final animation/geometry polish against a *real* notch cutout should
  happen on an actual notched MacBook.
- Notification mirroring is Accessibility- and macOS-version-dependent.
- Universal application builds and notarization/Developer ID signing are not produced by the
  current release script.
