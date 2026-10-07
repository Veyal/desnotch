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
  Also tune `NotchGeometry.topEar` (6) / `collapsedBottomRadius` (10) against the real cutout, and
  confirm the 520x720 transparent panel does not disturb menu-bar clicks.
- [x] Design and validate a universal arm64/x86_64 application build if Intel support is required.
  Host packaging remains the default; `UNIVERSAL=1` builds and verifies both slices.
- [x] Decide whether to add Developer ID signing, notarization, and a production bundle identity
  for external distribution.
- [x] Tag-driven release workflow (`release.yml`), `RELEASING.md`, vendored-adapter checksums
  (`VENDOR.sha256`), license/notice bundling, and a CI universal + hardened-runtime job.
- [ ] Exercise `release.yml` end to end with a real tag, and confirm the new `lint`,
  macos-15, and `universal-hardened` CI jobs are green; none of them can run on the Command Line
  Tools-only dev machine.
- [ ] Obtain Developer ID credentials and publish a signed, notarized build
  (`SIGNING_IDENTITY`, `NOTARIZE=1`; see `RELEASING.md`), then submit the cask upstream.
- [ ] Record the upstream `mediaremote-adapter` tag/commit in the vendor `NOTICE.md`; it is not
  recoverable from the vendored binary.

## P2 — optional polish

- [ ] Once SwiftLint has been run on CI at least once (it is not installed on the dev Mac), add
  `--strict` to the CI step and widen `.swiftlint.yml`. The two known warnings
  (`ClassifyTests.swift` trailing newline, `NotificationMirrorTests.swift` blank lines) are fixed.
- [x] Add a production app icon and complete external-distribution metadata if the app is shipped
  beyond local development.
