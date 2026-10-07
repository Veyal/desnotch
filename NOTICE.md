# Third-party notices

This project (desnotch) incorporates work from the following projects. See the
indicated files for full license text.

## mediaremote-adapter (BSD-3-Clause)

Source: https://github.com/ungive/mediaremote-adapter

Vendored at `Sources/DesnotchCore/MediaRemote/Vendor/MediaRemoteAdapter/`. Used to read
and control system-wide now-playing state via the private `MediaRemote.framework`,
loaded into `/usr/bin/perl`'s entitled process. Built as a stock universal binary via
the upstream project's own CMake build; not hand-modified. The exact bytes are pinned by
`VENDOR.sha256` in that directory, which `scripts/build-app.sh` verifies on every build.

Packaged apps carry this file, `LICENSE`, and `LICENSE-mediaremote-adapter` in
`Contents/Resources`, so the BSD-3-Clause notice accompanies every binary redistribution.

License: `Sources/DesnotchCore/MediaRemote/Vendor/MediaRemoteAdapter/LICENSE-mediaremote-adapter`

## agent-island (MIT)

Source: https://github.com/tristan666666/agent-island (Eric Park)

The detection pattern in `Sources/DesnotchCore/AgentActivity/AgentActivityScanner.swift`
(enumerate known session-log directories, skip sub-agent/automation fan-out, derive a
coarse state from file recency plus a turn-completion marker) is adapted from
agent-island's `SessionScanner.swift`. The per-format parsing detail
(Claude Code's `stop_reason`, Codex's `task_started`/`task_complete` markers, the
Codex header read, cwd-based labels, tail escalation) was derived independently in
this project. No source code from agent-island is included verbatim.
