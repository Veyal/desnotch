# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Now-playing data: private MediaRemote.framework

There is no public API for system-wide now-playing state/control. `Sources/desnotch/MediaRemote/MediaRemoteBridge.swift`
`dlopen`s `/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote` and `dlsym`s the
functions/notification-name constants it needs (`MRMediaRemoteGetNowPlayingInfo`,
`MRMediaRemoteRegisterForNowPlayingNotifications`, `MRMediaRemoteSendCommand`,
`kMRMediaRemoteNowPlayingInfoDidChangeNotification` and friends). This is the same technique
NotchNook/Alcove use, and it's a hard requirement of the brief, not a shortcut - none of these
symbols/keys are documented or guaranteed stable across macOS releases. If notification callbacks
stop firing or `MRMediaRemoteGetNowPlayingInfo` starts returning empty dictionaries after an OS
upgrade, suspect a renamed/removed private symbol first, not app logic.

The bridge is notification-driven only (no polling timer) to keep the app idle-cheap - preserve
that when touching `MediaRemoteBridge`/`NowPlayingController`.

## Notch geometry detection/fallback

`Sources/desnotch/UI/NotchGeometry.swift` detects a physical notch via `NSScreen.safeAreaInsets.top > 0`
and, when present, sizes the pill to the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`
(the two menu-bar-height regions macOS reserves either side of the camera housing). On a screen with
no notch (every non-MacBook display, including this project's Mac mini dev machine) it falls back to
a fixed-width capsule floating top-center. That fallback path is what actually gets exercised/tested
in this dev environment - real notch-hugging geometry has not been visually verified against physical
notch hardware; do that on an actual MacBook before trusting pixel-level positioning there.

## Build/run

See `README.md` for `swift run`/`swift build` and `scripts/build-app.sh` (release build + minimal
`.app` bundle + ad-hoc codesign). No Xcode project - SPM executable target only.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
