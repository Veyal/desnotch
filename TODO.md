# TODO — current readiness backlog

The historical remediation review is recorded in `CHANGELOG.md`. This file contains only
remaining work that is not already implemented in the current source tree.

## P0 — release confidence

- [ ] Confirm the hardened GitHub Actions workflow passes both `swift build` and `swift test` on
  `macos-14`. Local XCTest execution is unavailable with the installed Command Line Tools.
- [ ] Run a packaged-app smoke test on a machine with the required Accessibility/Calendar/media
  permissions and verify clean startup, menu actions, media control, and termination cleanup.

## P1 — hardware and distribution

- [ ] Validate physical-notch placement, collapsed/expanded geometry, screen changes, and menu-bar
  hit testing on a notched MacBook. The current development Mac mini exercises only the fallback.
- [ ] Design and validate a universal arm64/x86_64 application build if Intel support is required.
  The current release script intentionally packages the host architecture.
- [ ] Decide whether to add Developer ID signing, notarization, and a production bundle identity
  for external distribution.

## P2 — optional polish

- [ ] Add a production app icon and complete external-distribution metadata if the app is shipped
  beyond local development.
