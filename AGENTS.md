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
minutes without a file change (presumed hung); a completed turn stays `.needsYourTurn` for 5
minutes then fades to `.idle`; anything untouched for over 2 hours is dropped entirely. Only
`.working`/`.needsYourTurn`/`.stalled` sessions count as "activity" - purely `.idle` sessions
are tracked but excluded from the pill so old finished chats don't keep it open.

**Now-playing vs. agent-activity priority** (`NotchPillView.contentKind`): now-playing always
wins when visible, since it has real playback controls the user directly interacts with; agent
activity only takes the pill when now-playing has nothing to show. This is a simple two-mode
priority, not a combined/merged display - revisit if a future design wants both visible at once.

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
