# Third-party notice: MediaRemoteAdapter

`MediaRemoteAdapter.framework` and `mediaremote-adapter.pl` in this directory are
built from [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter),
used under the BSD 3-Clause License (see `LICENSE-mediaremote-adapter`).

Not modified from upstream; `MediaRemoteAdapter.framework` is a stock universal
(x86_64 + arm64) build via the project's own CMake build. See
`Sources/desnotch/MediaRemote/AdapterProcess.swift` for why this exists: as of
macOS 15.4, `MRMediaRemoteGetNowPlayingInfo` is entitlement-gated and returns
nothing when called in-process from a third-party binary; this project's own
`dlopen`/`dlsym` bridge (see git history) worked on earlier macOS but silently
returns nil now. mediaremote-adapter works around this by loading its adapter
code into `/usr/bin/perl`, an Apple-signed binary that *is* entitled to call
MediaRemote - the same technique used by `nowplaying-cli` and `media-control`.
