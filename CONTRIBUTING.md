# Contributing

desnotch is a SwiftPM-only macOS app (macOS 13+). There is no Xcode project.

## Build and run

```sh
swift build          # debug build
swift run            # run the app (no dock icon; use the menu bar item to quit)
scripts/build-app.sh # distributable dist/desnotch.app (see README.md)
```

## Tests

```sh
swift test
```

`swift test` needs an XCTest-capable toolchain (full Xcode). A machine with only the Command Line
Tools fails with `no such module 'XCTest'`; on such a machine run `swift build` locally and rely on
the GitHub Actions macOS runners, which are the authoritative test environment. Write new tests in
`Tests/DesnotchCoreTests` carefully so they compile without being run locally: check that every API
they call exists, and use an isolated `UserDefaults` suite for anything touching `SettingsStore`.

After packaging, the script checks run without XCTest:

```sh
scripts/smoke-test.sh dist/desnotch.app
scripts/runtime-smoke-test.sh dist/desnotch.app
```

## Lint

CI runs two linters (both are optional locally):

```sh
shellcheck scripts/*.sh
swiftlint lint --config .swiftlint.yml
```

`.swiftlint.yml` enables a deliberately small set of whitespace and redundancy rules. Also run
`bash -n` on any shell script you touch.

## Ground rules

- Read `AGENTS.md` before changing hover handling, the MediaRemote bridge, pill geometry or
  animation, or anything in `AgentActivity/`. It records load-bearing invariants and the privacy
  boundary (only counts and a project name may reach the UI; prompt text is opt-in and never in
  notifications).
- Keep changes small and match the surrounding style. Do not add third-party dependencies.
- `Sources/DesnotchCore/MediaRemote/Vendor/MediaRemoteAdapter/` is pinned by `VENDOR.sha256`;
  see its `NOTICE.md` before touching it.
- Add a bullet under `## Unreleased` in `CHANGELOG.md` for every user-visible change.
- Releases are cut from tags; see `RELEASING.md`.
