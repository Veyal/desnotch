# desnotch

Lightweight native macOS notch app: media now-playing live activity with animated open/close.

desnotch turns the MacBook notch into a small "Dynamic Island"-style live activity: when
something is playing system-wide (Music, Safari video, Spotify, etc.) a pill animates open
around the notch showing artwork, title, artist, and play/pause/next/previous controls that
actually control playback. It animates closed again after a short idle timeout with no
playback.

## Running in development

Requires Xcode's command line tools (for `swift`) - no Xcode GUI project needed.

```sh
swift run
```

`swift build` also works standalone. Both run from a clean checkout with zero manual setup.

The app has no dock icon and no menu bar item (`LSUIElement`/accessory activation policy) -
that's intentional MVP scope, not a bug. Quit with Cmd+Q while it has focus, or `pkill desnotch`.

## Building the distributable `.app`

```sh
scripts/build-app.sh
```

This runs `swift build -c release`, bundles the binary into `dist/desnotch.app` with a minimal
`Info.plist`, and ad-hoc codesigns it (`codesign --force --deep --sign -`). No notarization is
attempted for this MVP, so Gatekeeper will warn on other machines; right-click > Open (or
`xattr -dr com.apple.quarantine dist/desnotch.app`) to run it anyway. Drag `dist/desnotch.app`
to `/Applications`, or run it directly with `open dist/desnotch.app`.

## How it works

- **Now-playing data & control**: via the private `MediaRemote.framework`, since there is no
  public API for system-wide now-playing state. As of macOS 15.4, Apple entitlement-gated the
  relevant call, so it can no longer be called in-process (see `Sources/desnotch/MediaRemote/Vendor/MediaRemoteAdapter/NOTICE.md`
  for how this app works around that). Update delivery stays notification/stream-driven, never
  polled, so the app is idle-cheap (near-zero CPU at rest).
- **Notch geometry**: on a MacBook with a physical notch, the pill is sized and positioned
  using `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` to hug
  the actual notch cutout. On a screen with no notch (this project was developed on a
  Mac mini, which has none), it falls back to a fixed-width capsule floating top-center of
  the screen, in the same location a notch would occupy.

See `AGENTS.md` for implementation details load-bearing for anyone continuing this project.

## MVP limitations

- **No system notification mirroring/interception.** macOS has no reliable public API for
  reading other apps' notifications, and the private routes for it (Notification Center
  database scraping, etc.) are fragile and break across OS updates. Out of scope for this
  MVP by design - see the task brief.
- **Real notch geometry is untested on this dev machine.** This project was developed on a
  Mac mini, which has no physical notch, so notch-hugging geometry only ever exercised the
  fallback path here. Final animation/geometry polish against a *real* notch cutout should
  happen on an actual notched MacBook.
- Menu bar management, a file tray, widgets, and a settings UI are all explicitly out of
  scope for this first cut.
