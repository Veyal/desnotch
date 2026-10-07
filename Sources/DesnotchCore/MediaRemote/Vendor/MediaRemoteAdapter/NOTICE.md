# Third-party notice: MediaRemoteAdapter

`MediaRemoteAdapter.framework` and `mediaremote-adapter.pl` in this directory are
built from [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter),
used under the BSD 3-Clause License (see `LICENSE-mediaremote-adapter`).

Not modified from upstream; `MediaRemoteAdapter.framework` is a stock universal
(x86_64 + arm64) build via the project's own CMake build. See
`Sources/DesnotchCore/MediaRemote/MediaRemoteBridge.swift` for why this exists: as of
macOS 15.4, `MRMediaRemoteGetNowPlayingInfo` is entitlement-gated and returns
nothing when called in-process from a third-party binary; this project's own
`dlopen`/`dlsym` bridge (see git history) worked on earlier macOS but silently
returns nil now. mediaremote-adapter works around this by loading its adapter
code into `/usr/bin/perl`, an Apple-signed binary that *is* entitled to call
MediaRemote - the same technique used by `nowplaying-cli` and `media-control`.

## Provenance and integrity

- Upstream tag/commit: **not recorded** when this build was vendored. The framework's own
  `Info.plist` reports only `CFBundleVersion` 0.1.0, and the binary embeds no commit hash, so the
  release cannot be recovered from the files. Record the tag and commit here the next time the
  adapter is rebuilt or updated.
- `VENDOR.sha256` lists the SHA-256 of the framework Mach-O, its `Info.plist` and signature
  seal, the Perl script, and the license. `scripts/build-app.sh` runs `shasum -a 256 -c` against
  it for both the source tree and the copy that ships, and fails the build on any difference.
- To update the adapter: replace the files, record the upstream tag/commit above, regenerate
  the manifest from this directory with
  `shasum -a 256 mediaremote-adapter.pl LICENSE-mediaremote-adapter MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter MediaRemoteAdapter.framework/Versions/A/Resources/Info.plist MediaRemoteAdapter.framework/Versions/A/_CodeSignature/CodeResources > VENDOR.sha256`,
  and review the diff in the same commit.
