# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Now-playing data: private MediaRemote.framework via a vendored adapter subprocess

There is no public API for system-wide now-playing state/control; this app reads/writes it via
the private `MediaRemote.framework`. The original implementation called `MRMediaRemoteGetNowPlayingInfo`
in-process via `dlopen`/`dlsym` - the technique NotchNook/Alcove and most tutorials describe, and
it worked. **As of macOS 15.4, that call is entitlement-gated**: it resolves and executes without
error but silently returns nil for an arbitrary third-party binary (confirmed by direct
reproduction - real media playing, `MRMediaRemoteGetNowPlayingInfo` returning nil in-process while
an external tool using a different technique saw the real data at the same instant). Only specific
Apple-signed processes (e.g. `/usr/bin/perl`) pass that check now.

`Sources/desnotch/MediaRemote/MediaRemoteBridge.swift` now works around this by shelling out to
`Sources/desnotch/MediaRemote/Vendor/MediaRemoteAdapter/mediaremote-adapter.pl`, which loads
`MediaRemoteAdapter.framework` (also vendored there) into `/usr/bin/perl`'s already-entitled
process and streams now-playing JSON back over a pipe. This is the same technique `nowplaying-cli`
and `media-control` use. Both files are from [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
(BSD-3-Clause, see `Vendor/MediaRemoteAdapter/LICENSE-mediaremote-adapter` and `NOTICE.md`), built
as a stock universal (x86_64+arm64) binary via the project's own CMake build - not hand-modified.
They're declared as an SPM `resources:` in `Package.swift` (on the `DesnotchCore` library
target) and resolved at runtime via `MediaRemoteBridge.locateAdapter()`:
`Bundle.main.resourceURL/MediaRemoteAdapter` in a packaged `.app` (under `Contents/Resources`,
so the bundle is codesign-sealed/notarizable), with `Bundle.module` as the `swift run` fallback.
`scripts/build-app.sh` copies the adapter to `Contents/Resources/MediaRemoteAdapter` (the SPM
resource bundle is now `desnotch_DesnotchCore.bundle` after the library split). Missing
resources now log via `os.Logger` (`com.desnotch.app`) instead of failing silently.
The bridge stays push/notification-driven, not polled: the adapter's `stream` subcommand is one
long-lived subprocess that only writes a line when now-playing state actually changes, so idle CPU
stays near zero. Preserve that when touching `MediaRemoteBridge`/`NowPlayingController` - don't
replace `stream` with polling `get` on a timer. (The stream is now launched with `--debounce=100`
to coalesce a track-change's burst of updates; a `get` one-shot is used only as a reconciliation
fallback ~1.5s after a transport tap, in `NowPlayingController.reconcileWithGet`.)

Resilience is load-bearing too: all mutable stream state runs through one serial
`DispatchQueue` (`desnotch.mediaremote`), `stderr` goes to `/dev/null` (not an undrained pipe
that could deadlock perl), and a `terminationHandler` relaunches the stream with exponential
backoff (1s→30s) unless `stopStreaming()` set `isStopping`. Don't regress these when editing
`MediaRemoteBridge`.

If real media is playing but the pill still doesn't appear, first check literally whether
`/usr/bin/perl <path-to-mediaremote-adapter.pl> <path-to-MediaRemoteAdapter.framework> get` returns
real data from a plain shell - that isolates "is the adapter technique still entitled on this
macOS version" from "is desnotch's own code wrong."

**Command latency**: the `send` subprocess itself completes in ~15ms (measured) - it is not the
bottleneck for the ~1s play/pause round-trip. Most of that latency is downstream and outside this
app's control (target app processing the command, then the notification propagating back through
the adapter's `stream` subprocess). `NowPlayingController.togglePlayPause()` masks this with an
optimistic local flip rather than waiting for the round-trip; `applyRemote()` reconciles once the
real state arrives (a no-op if it already matches the guess). Don't try to "fix" the latency by
adding polling or shortening the adapter path - the subprocess spawn was never the slow part.

## Pill visibility: live-activity toast, not a persistent panel

The pill has three states: hidden, collapsed (small hoverable indicator at the notch), and
expanded. It does **not** stay expanded for the duration of playback - it expands briefly
(`autoCollapseDelay`, ~2.5s) on a real change event (new track, or a play/pause flip) and
auto-collapses again, like a toast. Hovering the collapsed indicator (`.onHover` in
`NotchPillView`, `setHovering(_:)`) is the only way to manually reopen it, and moving the mouse
away re-collapses it after a short grace period (`hoverExitDelay`). This applies to **both**
content modes now: the expand/collapse/hover state lives in one shared `NotchPillPresentation`
(`Sources/.../UI/NotchPillPresentation.swift`), used by both `NowPlayingController` and
`AgentActivityController`, so agent activity is also a toast, not a persistent panel.

Preserve the reveal-only-on-real-change guard when touching this: `NowPlayingController.applyRemote`
reveals only when the new `info` differs from the previous (so redundant re-deliveries of identical
state don't re-trigger the animation); `AgentActivityController.apply` reveals only when the
actionable count or its breakdown signature changes. Timers run on `.common` run-loop mode so they
keep firing during menu tracking. If you change this, keep the reveal guards and the shared
presentation as the single owner of `isExpanded`.

## Notch geometry detection/fallback

`Sources/desnotch/UI/NotchGeometry.swift` detects a physical notch via `NSScreen.safeAreaInsets.top > 0`
and, when present, sizes the pill to the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`
(the two menu-bar-height regions macOS reserves either side of the camera housing). On a screen with
no notch (every non-MacBook display, including this project's Mac mini dev machine) it falls back to
a fixed-width capsule floating top-center. That fallback path is what actually gets exercised/tested
in this dev environment - real notch-hugging geometry has not been visually verified against physical
notch hardware; do that on an actual MacBook before trusting pixel-level positioning there.

## AI agent activity pill mode

`Sources/desnotch/AgentActivity/` adds a second pill content mode alongside now-playing: a
generic summary of local Claude Code / Codex CLI session activity (e.g. "3 agents: 2 working,
1 needs you"). The detection pattern - enumerate known session-log directories, skip sub-agent/
automation fan-out, derive a coarse state from file recency plus a turn-completion marker - is
adapted from [agent-island](https://github.com/tristan666666/agent-island) (MIT, Eric Park)'s
`SessionScanner.swift`; the per-format parsing (Claude Code's `stop_reason`, Codex's
`task_started`/`task_complete` event markers) was derived independently against real session
files on the dev machine, not copied.

Hard privacy constraints for this feature, load-bearing for anyone touching it:
- All paths are built from `NSHomeDirectory()` (`~/.claude/projects`, `~/.codex/sessions`) -
  never a machine-specific literal.
- The UI (`NotchPillView.agentActivityContent`) only ever renders counts and generic labels
  (a project folder's basename) via `AgentActivitySummary`/`AgentSession.projectLabel` - never
  raw transcript content, prompts, or full absolute paths. Keep new UI additions on that side
  of the boundary: read whatever you need for classification, but only ever pass a basename or
  a count out to the view layer.
- `AgentActivityScanner` skips Claude Code `subagents/` paths and `agent-*.jsonl` files, and
  Codex sessions whose `originator`/`source` indicate automation (`exec`, `codex_exec`, etc.) -
  these are sub-agent/headless fan-out, not a person's session worth surfacing.

State model (`AgentActivityScanner.classify`): a turn in progress becomes `.stalled` after 10
minutes without a file change (presumed hung); a presumed-hung session is dropped entirely after
`stalledSessionMax` (45 min) so dead sessions don't inflate the count for the full 2h lookback;
a completed turn stays `.needsYourTurn` for 5 minutes then fades to `.idle`; anything untouched for
over 2 hours is dropped. Only `.working`/`.needsYourTurn`/`.stalled` sessions count as "activity" -
purely `.idle` sessions are tracked but excluded from the pill so old finished chats don't keep it open.

**Now-playing vs. agent-activity priority** (`NotchPillView.contentKind`): now-playing wins while
it is actively playing or expanded, since it has real playback controls the user directly interacts
with; but paused/stopped media *yields* to agent activity (so a paused track doesn't pin the dot and
bury a working agent). When media is paused and no agent is active, a collapsed now-playing
indicator still shows so the user can resume. This is a simple two-mode priority, not a
combined/merged display - revisit if a future design wants both visible at once.

`AgentActivityController` polls the scanner on a 5s timer (file changes have no OS notification
to hook, unlike `MediaRemoteBridge`) - keep that off the main actor if you touch it, per the
existing `Task.detached` pattern.

## Build/run

See `README.md` for `swift run`/`swift build` and `scripts/build-app.sh` (release build + minimal
`.app` bundle + ad-hoc codesign). No Xcode project - SPM executable target only.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
