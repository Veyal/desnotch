# Releasing

Releases are tag-driven. Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds,
checks, and publishes a GitHub Release. Nothing is published from a developer machine.

## Cut a release

1. On `main`, rename `## Unreleased` in `CHANGELOG.md` to `## vX.Y.Z — YYYY-MM-DD` (keep the
   same bullets) and add a fresh empty `## Unreleased` above it if you want one.
2. Confirm CI is green on that commit (build, tests on macos-14 and macos-15, lint, and the
   universal hardened-runtime job).
3. Tag and push (a maintainer action; never done by automation):

   ```sh
   git tag -a vX.Y.Z -m "desnotch vX.Y.Z"
   git push origin vX.Y.Z
   ```

The workflow then:

- derives `X.Y.Z` from the tag and fails unless `CHANGELOG.md` has a non-empty `## vX.Y.Z`
  section (`scripts/changelog-section.sh X.Y.Z`; that section becomes the release notes);
- runs `swift test`;
- builds `UNIVERSAL=1 HARDENED_RUNTIME=1 VERSION=X.Y.Z scripts/build-app.sh` and fails unless the
  built `Info.plist` reports `CFBundleShortVersionString` `X.Y.Z`;
- runs `scripts/smoke-test.sh` with `REQUIRE_UNIVERSAL=1` and `scripts/runtime-smoke-test.sh`;
- zips with `ditto` as `desnotch-vX.Y.Z-universal.zip`, writes
  `desnotch-vX.Y.Z-universal.zip.sha256`, and creates the GitHub Release with both attached and
  the checksum appended to the notes.

You can dry-run most of this locally:

```sh
scripts/changelog-section.sh X.Y.Z          # the notes that would be published
UNIVERSAL=1 HARDENED_RUNTIME=1 VERSION=X.Y.Z scripts/build-app.sh
REQUIRE_UNIVERSAL=1 scripts/smoke-test.sh dist/desnotch.app
scripts/runtime-smoke-test.sh dist/desnotch.app
```

## After the release

Homebrew installs come from the separate tap `Veyal/homebrew-desnotch` (`Casks/desnotch.rb`).
A release is not complete until the cask points at the published zip with its exact SHA-256
(from the `.sha256` asset). Validate with `brew style`, `brew audit --strict --online`,
`brew livecheck`, and a real install/upgrade.

## Signing and notarization

CI builds are ad-hoc signed, so first launch needs the Gatekeeper confirmation described in
`README.md`. A Developer ID build with notarization is opt-in and runs on a machine that holds the
credentials; `scripts/build-app.sh` supports it through environment variables only:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" HARDENED_RUNTIME=1 \
UNIVERSAL=1 VERSION=X.Y.Z NOTARIZE=1 NOTARY_PROFILE=desnotch-notary scripts/build-app.sh
```

For an App Store Connect API key use `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, and (for team keys)
`NOTARY_ISSUER_ID` instead of `NOTARY_PROFILE`. The script requires an `Accepted` result, staples
the ticket, and runs `stapler validate` and `spctl --assess`. Attach a notarized zip to the
release by hand (`ditto -c -k --keepParent dist/desnotch.app desnotch-vX.Y.Z-universal.zip`), and
do not let it be replaced by the ad-hoc CI artifact. Never commit keys or profiles.

## Vendored adapter

`scripts/build-app.sh` verifies `Sources/DesnotchCore/MediaRemote/Vendor/MediaRemoteAdapter`
against `VENDOR.sha256` on every build. When updating the adapter, regenerate the manifest as
described in that directory's `NOTICE.md` and record the upstream tag and commit.
