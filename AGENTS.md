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

`Sources/DesnotchCore/MediaRemote/MediaRemoteBridge.swift` now works around this by shelling out to
`Sources/DesnotchCore/MediaRemote/Vendor/MediaRemoteAdapter/mediaremote-adapter.pl`, which loads
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

## Pill visibility: always-visible notch, expands on hover only

The notch is ALWAYS rendered (even with nothing active it hosts the calendar glance + file
tray; on real hardware the empty state is invisible black-on-black). Hover expands it;
exit collapses after a `hoverExitDelay` grace. **Hover has exactly one authority**:
`NotchWindowController.updateInteractivity()`'s cursor-in-pill-rect test, fed by
global+local mouse monitors (`.mouseMoved` + `.leftMouseDragged` - the latter so file
drags reach the tray's drop target). SwiftUI `.onHover` was removed deliberately: its
exit events raced panel resizes and stranded the pill open or closed (the "popup closes
after 1s while still hovering" bug). Don't reintroduce it. The same test drives
`panel.ignoresMouseEvents` so menu-bar clicks outside the pill rect pass through. The
expanded pill stacks every section at once - no priority switch. An agent needing
attention changes the wing icon (lightning, yellow) but does NOT force the pill open.

The expanded pill has a **fixed width** (`NotchPillView.expandedBaseWidth`, 300pt; on a notch
screen at least cutout + 2 wings). This is deliberate: the rows contain greedy `Spacer`s, so
without a fixed width the pill fills whatever the panel proposes and the measured size feeds
back into the panel's grow-only sizing. Keep the fixed width (and the per-text `maxWidth` caps)
when adding content - don't let the expanded pill become content-width-driven again.

## Notch geometry: never draw behind the cutout

`Sources/DesnotchCore/UI/NotchGeometry.swift` detects a physical notch via
`NSScreen.safeAreaInsets.top > 0` and computes the cutout size (`notchSize(for:)`) from
`auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. On a notch screen the panel is anchored flush
with the screen top and the pill renders as a solid-black bottom-rounded extension of the
hardware: minimized = two `wingWidth` wings flanking a `Color.clear` gap exactly the cutout's
width (indicators live in the wings, **never behind the cutout - that area is opaque hardware
and anything drawn there is invisible**); expanded = same shape, all content pushed below the
cutout via `.padding(.top, notch.height + 4)`. Solid `.black` fill (not 0.85 opacity) so it
blends seamlessly with the hardware. On a screen with no notch (every non-MacBook display,
including this project's Mac mini dev machine) the layout is **identical**: it renders around
a synthetic MacBook-sized cutout (`NotchPillView.fakeNotchSize`, 200×30pt of plain black in
the middle, wings either side) drawn over the menu bar top-center, so both screen types
share one code path via `effectiveNotch`. The fallback path is what gets exercised in this
dev environment;
the notch path was built for a MacBook Pro 14" report that the old top-centered layout was
hidden behind the hardware - verify pixel fit on real hardware after geometry changes.

## AI agent activity pill mode

`Sources/DesnotchCore/AgentActivity/` adds a second pill content mode alongside now-playing: a
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
- The UI (`NotchPillView.agentSection`) only ever renders counts, generic labels (a project
  folder's basename via `AgentSession.projectLabel`), and `AgentSession.taskTitle` - a
  first-prompt-derived hint the owner explicitly opted into, hard-truncated to
  `AgentActivityScanner.taskTitleMax` (48 chars), first line only, with harness noise
  (`<...>` wrappers, "Caveat:") rejected. Never full prompts, transcript bodies, or absolute
  paths. Keep new UI additions on that side of the boundary, and keep the title cap tight -
  the pill is permanently on screen and this user screenshots/screen-shares constantly.
- `AgentActivityScanner` skips Claude Code `subagents/` paths and `agent-*.jsonl` files, and
  Codex sessions whose `originator`/`source` indicate automation (`exec`, `codex_exec`, etc.) -
  these are sub-agent/headless fan-out, not a person's session worth surfacing.

State model (`AgentActivityScanner.classify`): a turn in progress becomes `.stalled` after 10
minutes without a file change (presumed hung); a presumed-hung session is dropped entirely after
`stalledSessionMax` (45 min) so dead sessions don't inflate the count for the full 2h lookback;
a completed turn stays `.needsYourTurn` for 5 minutes then fades to `.idle`; anything untouched for
over 2 hours is dropped. Only `.working`/`.needsYourTurn`/`.stalled` sessions count as "activity" -
purely `.idle` sessions are tracked but excluded from the pill so old finished chats don't keep it open.

There is no now-playing-vs-agents priority switch anymore: the expanded pill stacks both
sections at once, and the minimized state shows both indicators side by side (or one per wing
on a notch screen).

`AgentActivityController` polls the scanner on a 5s timer (file changes have no OS notification
to hook, unlike `MediaRemoteBridge`) - keep that off the main actor if you touch it, per the
existing `Task.detached` pattern.

## Other pill sections & gestures (v0.3.2)

- **Volume on scroll** (`SystemVolume`, CoreAudio `VirtualMainVolume`; monitor in
  `NotchWindowController`): scrolling over the pill adjusts the default output device's
  volume with a brief bar readout (`NotchPillPresentation.flashVolume`). Verified working
  on the mini's output device; some external DACs have no settable volume - `adjust`
  returns nil and the gesture is a silent no-op there.
- **Needs-you notifications** (`AgentAttentionNotifier`): fires when a session newly flips
  to `.needsYourTurn` (keyed by source|project|title across scans, seeded silently on the
  first scan after launch). Uses `UNUserNotificationCenter` only in a packaged `.app` -
  a bare `swift run` binary has no bundle identity and would crash, so it falls back to
  `NSSound`. Toggleable from the status menu (`notifyAgentNeedsYou` default, on by default).
- **Calendar glance** (`CalendarController`, EventKit): next non-all-day event within 12h as
  an expanded row; it keeps the pill alive on its own only when imminent (<30 min or
  ongoing). Usage-description keys live in `scripts/build-app.sh`'s Info.plist. If access is
  denied or can't be prompted (headless/SSH bare binary), the row just never appears.
- **Stuck-process detector** (`ProcessMonitorController`): samples `ps -axo pid,pcpu,comm`
  every 30s; a process sustaining ≥90% CPU for ≥10 min is flagged (pill section + one
  notification per streak). The sustained window is the point - don't "simplify" it to a
  single high-CPU sample, that just flags every compile.

- **File tray** (`TrayController`): drop files onto the notch shape (SwiftUI `.onDrop` of
  `.fileURL`); stores path references only (UserDefaults-persisted, dead paths pruned on
  load, 8 max). Rows: click opens, drag out re-exports via `NSItemProvider`, ✕ removes.
  Drag delivery depends on the `.leftMouseDragged` monitors making the panel interactive
  mid-drag (Dropover-style; verify on hardware if drops ever stop landing).
- **Now-playing timeline**: `NowPlayingInfo.duration/elapsed/elapsedAt` (adapter `duration`/
  `elapsedTime`/`timestamp`; excluded from `==` on purpose - they change every delivery).
  Position is extrapolated client-side (`position(at:)`) and ticked by a 1s `TimelineView`
  only while rendered - no extra adapter polling. Hidden when the source reports no
  duration (radio/streams).

Compact wing priority when several things are active: left = media > stuck-process >
calendar; right = agents > stuck-process. Everything else is one hover away.

v0.4.0 additions, one line each: rows are clickable (media → source app via
`bundleIdentifier`; agent → first running app in `NotchPillView.agentHostBundleIDs`, else
reveal `AgentSession.projectPath` - a click-to-jump-only field, NEVER rendered); the
needs-you wing icon bounces on count change (macOS 14+ symbolEffect); `BatteryController`
(IOKit push notifications, plug/unplug flashes the pill open, nil state on desktops);
`UpdateChecker` (daily GitHub latest-release poll, status-menu item; inert in dev builds
with no bundle version; `isVersion(_:newerThan:)` is tested); `MediaUseMonitor` (5s poll
of CoreAudio/CMIO "running somewhere" - no capture permission needed - orange mic/green
camera dots overlaid top-trailing on the shape); privacy mode (`privacyModeEnabled`,
default OFF, quick toggle in the status menu) blanks agent task titles and calendar
titles; tray drag-out uses `NSItemProvider(contentsOf:)` (real Finder copies) and
QuickLook thumbnails cached in `TrayController.thumbnails`.

Review-remediation notes (2026-07-31), keep these invariants: `updateForScreenChange`
must ALWAYS call `applyPlacement` after the grow-only `resize` (the grow-only guard
alone leaves the panel at stale coordinates after a resolution/display change). The
status menu is rebuilt on every open (`AppDelegate.rebuildMenu`, via NSMenuDelegate) and
is the ONLY keyboard/VoiceOver path to media transport, agent jump, and tray - the panel
itself is non-activating and unreachable by assistive tech; keep new pill actions
mirrored there. Notification permission is requested at launch, not lazily (a lazy
request dropped the triggering notification). Scanner title/cwd/Codex-header facts are
cached in `AgentActivityScanner` (lock-guarded, nil results retried, cap-bounded) - keep
new derived-from-file facts behind that cache. The agent publish signature includes an
elapsed-minutes bucket so row times/ordering refresh ~1/min. Calendar queries run off
the main actor (`queryNextEvent`) and permission is only requested once the feature is
enabled. CI (.github/workflows/ci.yml, macos-14) is where tests actually run.

Pill behavior/sizing is user-configurable via `SettingsStore` (Settings window):
`pillMode` (hover-auto vs always-expanded), `hoverCollapseDelay`, `minimizedWidth/Height`
(the synthetic cutout - real notch hardware always wins), `expandedWidth` (still floored
at cutout+wings via `NotchGeometry.expandedPillWidth`, which keeps the no-feedback-loop
fixed-width rule intact). All numeric knobs are clamped to their `SettingsStore.*Range`
bounds on read AND write - keep new knobs on that pattern. Tests:
`SettingsStoreTests.swift` (isolated UserDefaults suite; runs under Xcode/CI only).

## Build/run

See `README.md` for `swift run`/`swift build` and `scripts/build-app.sh` (release build + minimal
`.app` bundle + ad-hoc codesign). No Xcode project - SPM executable target only.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
