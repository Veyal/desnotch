# TODO — current readiness backlog

The historical remediation review is recorded in `CHANGELOG.md`. This file contains only
remaining work that is not already implemented in the current source tree.

## P0 — release confidence

- [x] Confirm the hardened GitHub Actions workflow passes both `swift build` and `swift test` on
  `macos-14`. Local XCTest execution is unavailable with the installed Command Line Tools.
- [x] Run the packaged app with Accessibility and Calendar granted; verify clean
  startup, status-menu parity, owned display-awake start/stop, menu Quit, and adapter cleanup.
- [x] Verify now-playing menu transport and volume scroll with an active real media session.

## P1 — hardware and distribution

- [ ] Validate physical-notch placement, collapsed/expanded geometry, screen changes, and menu-bar
  hit testing on a notched MacBook. The current development Mac mini exercises only the fallback.
- [x] Design and validate a universal arm64/x86_64 application build if Intel support is required.
  Host packaging remains the default; `UNIVERSAL=1` builds and verifies both slices.
- [x] Decide whether to add Developer ID signing, notarization, and a production bundle identity
  for external distribution.

## P2 — optional polish

- [x] Add a production app icon and complete external-distribution metadata if the app is shipped
  beyond local development.
