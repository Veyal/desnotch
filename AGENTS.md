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
backoff (1s→30s, `AdapterRestartBackoff`) unless `stopStreaming()` set `isStopping`. The backoff
resets only after the adapter emits a valid JSON line or stays up >=10s - never at launch, or a
crash-on-start adapter would respawn perl every second forever. Every perl launch goes through
`MediaRemoteBridge.makeAdapterProcess` with `SubprocessRunner.sanitizedEnvironment()` (no
`PERL5OPT`/`PERL5LIB`/`DYLD_*`), and pipe/termination callbacks carry a stream generation so bytes
from a dead adapter can't corrupt the next stream's first line. Don't regress these when editing
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

## Pill visibility: always-visible notch, hover-controlled in auto mode

The notch is ALWAYS rendered (even with nothing active it hosts the calendar glance + file
tray; on real hardware the empty state is invisible black-on-black). In hover-auto mode,
hover expands it and exit collapses after a `hoverExitDelay` grace. **Hover has exactly one authority**:
`NotchWindowController.updateInteractivity()`'s cursor-in-pill-rect test, fed by
global+local mouse monitors (`.mouseMoved` + `.leftMouseDragged` - the latter so file
drags reach the tray's drop target). SwiftUI `.onHover` was removed deliberately: its
exit events raced panel resizes and stranded the pill open or closed (the "popup closes
after 1s while still hovering" bug). Don't reintroduce it. The same test drives
`panel.ignoresMouseEvents` so menu-bar clicks outside the pill rect pass through. The
expanded pill stacks every section at once - no priority switch. An agent needing
attention changes the wing icon (lightning, yellow) but does NOT force the pill open.
An active voice session does: any `VoiceSessionModel` phase other than `.idle` sets
`voiceActive`, which holds the pill open.

Keyboard/VoiceOver users cannot hover, so `NotchWindowController.isPinnedOpen` (status menu "Show
Notch" and the opt-in `globalHotkeyEnabled` Carbon `RegisterEventHotKey` shortcut, which needs no
Accessibility permission) feeds the SAME `updateInteractivity()` decision via
`PillInteractionPolicy.wantsHover(cursorInside:pinnedOpen:voiceActive:)`. The cursor, the pin,
and `voiceActive` are three inputs to that one decision, not extra hover sources, and neither
the pin nor `voiceActive` changes `ignoresMouseEvents` (`acceptsMouse` stays cursor-only).
The display that hosts the pill is chosen by
`DisplaySelection.preferredIndex` (Settings `pillDisplay`, else a notch display, else
`NSScreen.screens.first`; never the focus-dependent `NSScreen.main`). `AccessibilityAnnouncer`
posts VoiceOver announcements; never announce banner, reminder, agent, or voice transcript,
reply, or command text, only that an event happened.

The expanded pill has a **fixed width** (`SettingsStore.expandedWidth`, 300pt by default; on a
notch screen at least cutout + 2 wings, and never below the minimized pill's `compactWidth`). This is deliberate: the rows contain greedy `Spacer`s, so
without a fixed width the pill fills whatever the panel proposes and the measured size feeds
back into the panel's grow-only sizing. Keep the fixed width (and the per-text `maxWidth` caps)
when adding content - don't let the expanded pill become content-width-driven again. Natural
size is reported through the single `PillContentSizePreferenceKey`; don't split width/height into
separate callbacks, which doubles panel resize and interactivity work during animations. Never add
broad `.animation` modifiers to the root; structural and content motion have separate authorities
described under Motion vocabulary below.

## Notch geometry: never draw behind the cutout

`Sources/DesnotchCore/UI/NotchGeometry.swift` detects a physical notch via
`NSScreen.safeAreaInsets.top > 0` and computes the cutout size (`notchSize(for:)`) from
`auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. On a notch screen the panel is anchored flush
with the screen top and the pill renders as a solid-black bottom-rounded extension of the
hardware: minimized = two `wingWidth` wings flanking a `Color.clear` gap exactly the cutout's
width (indicators live in the wings, **never behind the cutout - that area is opaque hardware
and anything drawn there is invisible**); expanded = same shape, all content pushed below the
cutout via `.padding(.top, notch.height + NotchGeometry.contentTopGap)`. Solid `.black` fill (not 0.85 opacity) so it
blends seamlessly with the hardware. On a screen with no notch (every non-MacBook display,
including this project's Mac mini dev machine) the layout is **identical**: it renders around
a synthetic MacBook-sized cutout (`effectiveNotch`, default 200×30pt from
`SettingsStore.minimizedWidth`/`minimizedHeight`, plain black in the middle, wings either side)
drawn over the menu bar top-center, so both screen types share one code path via `effectiveNotch`. The fallback path is what gets exercised in this
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
  folder's basename via `AgentSession.projectLabel`, or the generic word "project" when the
  cwd is unknown - never the encoded directory name), and `AgentSession.taskTitle` - a
  first-prompt-derived hint behind the OFF-by-default `agentTaskTitlesEnabled` setting
  (`scan(..., includeTaskTitles:)`: with it off no prompt text is read), hard-truncated to
  `AgentActivityScanner.taskTitleMax` (48 chars), first line only, with harness noise
  (`<...>` wrappers, "Caveat:") rejected. Never full prompts, transcript bodies, or absolute
  paths. Notifications use the project label only, never the title. Keep new UI additions on
  that side of the boundary, and keep the title cap tight -
  the pill is permanently on screen and this user screenshots/screen-shares constantly.
- `AgentActivityScanner` skips Claude Code `subagents/` trees (never descended: `skipDescendants`)
  and `agent-*.jsonl` files, headless Claude runs (`entrypoint: "sdk-cli"`, read with the cwd and
  cached with it), and Codex sessions whose `originator`/`source` indicate automation (`exec`,
  `codex_exec`, etc., or an object-valued `source` such as `{"subagent": {...}}`) - these are
  sub-agent/headless fan-out, not a person's session worth surfacing. A user-interrupted turn
  (Codex `turn_aborted`, Claude's `[Request interrupted by user...]` entry) reads as waiting on you,
  not as a turn in progress.

Code layout: `AgentActivityScanner` (public API, constants, `classify`) orchestrates the `AgentSessionSource`
conformers (`ClaudeCodeSessionSource`, `CodexSessionSource`, `PiSessionSource`, `OpenCodeSessionSource`, one file each);
shared caches and byte-level transcript readers live in `AgentScanSupport.swift`. A new provider is a new
`AgentSessionSource` added to `AgentActivityScanner.sources`. `NotchPillView` is split the same way into
`NotchPillView+<Section>.swift` extensions; the body, expansion choreography and `pillContent` stay in `NotchPillView.swift`.

State model (`AgentActivityScanner.classify`): a turn in progress becomes `.stalled` after 10
minutes without a file change (presumed hung); a presumed-hung session is dropped entirely after
`stalledSessionMax` (45 min) so dead sessions don't inflate the count for the full 2h lookback;
a completed turn stays `.needsYourTurn` for 5 minutes then fades to `.idle`; anything untouched for
over 2 hours is dropped. Only `.working`/`.needsYourTurn`/`.stalled` sessions count as "activity" -
purely `.idle` sessions are tracked but excluded from the pill so old finished chats don't keep it open.

There is no now-playing-vs-agents priority switch anymore: the expanded pill stacks both
sections at once, and the minimized state shows both indicators side by side (or one per wing
on a notch screen).

`AgentActivityController` polls the scanner on a 5s cadence (file changes have no OS notification
to hook, unlike `MediaRemoteBridge`) - keep the scan itself off the main actor if you touch it (it
runs on a plain dispatch queue). Like `MediaUseMonitor` (which only polls as a fallback) and
`ProcessMonitorController`, the loop is
started/cancelled from its `SettingsStore` flag and from `PollingActivity.isSuspended` (displays or
system asleep, session resigned), and `PollingActivity.scaled(_:)` stretches the interval in Low
Power Mode. New polling loops should follow that pattern; push-driven sources (the MediaRemote
stream) must not. The process monitor samples via `SubprocessRunner` (`PSProcessSampler`), a full
`ps` scan every 30s and a pid-scoped `ps -p` refresh while processes are flagged; libproc was
rejected because `proc_pidinfo` cannot read root-owned processes from a user session.

## Other pill sections & gestures (v0.3.2)

- **Volume on scroll** (`SystemVolume`, CoreAudio `VirtualMainVolume`; monitor in
  `NotchWindowController`): scrolling over the pill adjusts the default output device's
  volume with a brief bar readout (`NotchPillPresentation.flashVolume`). Verified working
  on the mini's output device; some external DACs have no settable volume - `adjust`
  returns nil and the gesture is a silent no-op there.
- **Needs-you notifications** (`AgentAttentionNotifier`): fires when a session newly flips
  to `.needsYourTurn` (keyed by `AgentSession.identityKey`, an opaque hash of the transcript
  path, across scans; seeded silently on the first scan after launch). Uses
  `UNUserNotificationCenter` only in a packaged `.app` - a bare `swift run` binary has no
  bundle identity and would crash, so it falls back to `NSSound`. The notifier is delivery
  only; callers gate on `SettingsStore.notifyAgentNeedsYou` (agents) and
  `notifyStuckProcess` (stuck-process detector), both on by default.
- **Calendar glance** (`CalendarController`, EventKit): next non-all-day event within 24h as
  an expanded row; it keeps the pill alive on its own only when imminent (<30 min or
  ongoing). Usage-description keys for Calendar, Reminders, Microphone
  (`NSMicrophoneUsageDescription`), and Speech Recognition
  (`NSSpeechRecognitionUsageDescription`) live in `scripts/build-app.sh`'s Info.plist.
  Microphone and speech are requested only after voice is enabled. If Calendar access is
  denied or can't be prompted (headless/SSH bare binary), the row just never appears. A Join
  action is exposed only for recognized HTTP(S) conferencing hosts found in the event URL,
  bounded location, or bounded notes. Location/notes are never rendered or persisted, and the
  same Join action must remain mirrored in the status menu.
- **Actionable reminders** (`RemindersController`, EventKit, OFF by default): shows one incomplete
  reminder (overdue first, otherwise nearest due within seven days), with complete and bounded
  quick-capture actions mirrored in the status menu. Permission is requested only after enablement;
  queries are generation-checked and stop when disabled. Like `CalendarController` it caches the
  delivered flag (`isFeatureEnabled`): `@Published` emits before it stores, so never re-read
  `settings.<flag>` inside its own sink. The 30s tick only re-reads the clock (and stops while
  `PollingActivity` is suspended); EventKit is fetched on store changes, wake, a clock-state flip and
  every 10 min. Titles are bounded before publication,
  pass through `privacyRedacted`, and are never logged or persisted by desnotch. Quick capture writes
  directly to the default Reminders list; do not add a parallel reminder store.
- **Stuck-process detector** (`ProcessMonitorController`): derives interval CPU from accumulated
  `ps` CPU time every 30s (5s while a flag is visible); a process sustaining ≥90% CPU for ≥10
  min is flagged (pill section + one notification per streak). Do not use `ps %cpu` here - it is
  a decaying average and leaves recovered processes looking hot. The sustained window is the point;
  don't "simplify" it to a single high-CPU sample, which would flag every compile.
- **Utility actions**: Privacy mode is the pill's only always-present action. Keep the
  low-frequency display-awake control in the status menu; `DisplayAwakeController` owns its
  `/usr/bin/caffeinate -d -w <desnotch-pid>` subprocess, which is session-scoped and must stop on
  toggle-off/app exit. Never discover or terminate caffeinate processes launched outside desnotch.

- **File tray** (`TrayController`): drop files onto the notch shape (SwiftUI `.onDrop` of
  `.fileURL`); stores path references only (UserDefaults-persisted, dead paths pruned on
  load, 8 max). Rows: click opens, drag out re-exports via `NSItemProvider`, and the
  context/status menus mirror open, reveal in Finder, copy, share, and remove. These actions
  operate on validated live tray references and never move/delete the underlying file.
  Drag delivery depends on the `.leftMouseDragged` monitors making the panel interactive
  mid-drag (Dropover-style; verify on hardware if drops ever stop landing).
- **Focus timer** (`FocusTimerController`): one session-scoped 5/15/25/50-minute live
  activity, started from the status menu and controlled from both menu and pill. It keeps an
  absolute `Date` deadline, one non-repeating wall-clock completion timer, and derives progress
  in `TimelineView` (1 Hz while running, a no-op hourly period otherwise); never replace this with a
  repeating controller poll or persistence. Pausing stores only remaining duration in memory.
  Completion is a transient token + callback used for the pill reveal/sound/VoiceOver announcement,
  and the completed row remains until dismissed or a new timer starts.
- **Clipboard pocket** (`ClipboardController`, OFF by default): stores up to eight bounded
  plain-text copies in memory only and clears on disable/exit. It polls `NSPasteboard.changeCount` (on the `PollingActivity` gate: stopped while displays/system sleep, stretched in Low Power Mode)
  before reading, skips concealed/transient/password-manager marker types, and never persists or
  logs content. Keep clipboard previews behind `privacyRedacted`; copy/remove/clear must remain
  mirrored in the status menu.
- **Now-playing timeline**: `NowPlayingInfo.duration/elapsed/elapsedAt` (adapter `duration`/
  `elapsedTime`/`timestamp`; excluded from `==` on purpose - they change every delivery).
  Position is extrapolated client-side (`position(at:)`) and drawn by a `TimelineView` at
  `PillProgressCadence` (typically 1-2 fps; 1/15 s only as a floor for very short tracks) only while
  expanded and playing - no extra adapter polling. Hidden when the
  source reports no duration (radio/streams).
- **Stale-session policy** (`NowPlayingInfo.hasContent`/`pausedExpiry`): browser media
  sessions are never unregistered while the tab lives, so residue lingers system-wide
  (observed: WhatsApp Web's 40ms notification ping titled "(5) WhatsApp" reported for
  hours). Non-playing items with sub-second duration are filtered outright (never while
  playing - streams misreport duration); anything paused expires from the pill
  `pausedRetention` (15 min) after its adapter timestamp, via a timer in
  `NowPlayingController.updatePausedExpiry` (the change-driven stream sends nothing
  further for a paused item, so a timer is the only staleness signal). Every path that
  sets `info` must call `updatePausedExpiry()`. Preserve the playing-item fallback cache
  only across a short foreground interruption; authoritative nil/paused long-form updates
  clear it. Reconciliation `get` calls distinguish successful-empty from failure, stay
  timeout-bounded off the stream queue, and carry a generation so an older result cannot
  overwrite a newer stream update or transport action.

- **Notification mirror** (`Sources/DesnotchCore/NotificationMirror/`, v0.4.x, OFF by
  default): mirrors other apps' notification banners via an `AXObserver` on the
  `com.apple.notificationcenterui` process (window-created events → bounded AX text
  walk). This is deliberately the ONLY approach used: the notifications SQLite DB is
  Full-Disk-Access-gated since Sequoia (verified locally on 15.5) and `usernoted` XPC
  is private - do not "upgrade" to either. Needs the Accessibility permission; the
  Settings pane owns the grant/retry/denied flow and the controller self-rechecks
  trust every 5s while denied (on the `PollingActivity` gate, like the other loops). Privacy invariants: banner content lives ONLY in
  `NotificationMirrorController.latest` (memory, 60s lifetime), is hard-capped at
  `MirroredNotification.contentMax`, goes through `privacyRedacted` in the UI, and is
  never persisted or put in the status menu (menu shows app name only). Muted apps
  persist as lowercased display names (`SettingsStore.mutedNotificationApps`).
  Sequoia's SwiftUI Notification Center exposes banner text via
  `AXAttributedDescription`/`AXDescription`, not static texts - `collectText` tries
  those per node; parsing tolerates comma-joined and newline-separated shapes
  (`MirroredNotification.parse`, tested). Banner-shape drift across macOS releases is
  expected - fix the parser, not the architecture. `chunkNoise` strips AX scaffolding
  ("Notification Center", Close/Options/...) BEFORE app identification: the host
  window's title is also the NotificationCenter process's display name, so without it
  the running-app scan claims it and every row is titled "Notification Center".
  "Hide the macOS banner" (`dismissSystemBanners`, off by default) is implemented as
  dismiss-after-mirroring (AX press on the banner's close affordance, 0.35s after
  arrival), NOT suppression: nothing lets a third party stop a banner from being
  created, and Focus/DND - the only real suppression - would also stop the AX
  window-created event and blind the mirror. Don't "upgrade" this to DND toggling.
  Only banners this app actually mirrored are dismissed (muted apps keep their normal
  system banner); Notification Center history is never touched.

Compact wing priority when several things are active (`WingSelection`): left = voice > volume > media >
focus timer > stuck-process > calendar > urgent reminder; right = voice (only while listening or
awaiting approval) > volume > agents > timer displaced by media > notification > displaced
stuck-process/calendar/reminder. Everything else is one hover away.

Wing and stack sizing: `WingMetrics` (`WingIndicator.swift`) grows BOTH wings by `extraWidth` when the
timer's ring + "25m" label or a two-digit agent count would sit within `minimumInset` of an edge, and adds
`privacyLane` per side while the mic/camera dots show (the dots live in that lane, never on a wing
indicator); the compact frame animates on `motion.wing`; the expanded width is independent except that it is floored at `compactWidth`, so hovering never narrows the shape. Its
constants are measured font widths pinned by `WingMetricsTests` - re-measure when a size changes. The
expanded stack is not scrollable (scroll adjusts volume), so `PillRowCaps`/`PillStackEstimate` trim
the lists to the screen height in fixed tiers (a pure function of counts, never of the measured size).
Anything time-derived in the expanded layer (countdowns, due labels, ages) goes through `PillClock`;
state the collapsed wings derive from the clock (`isImminent`, `isUrgent`) is republished by the
controllers' `clockRevision`. Never read props through `self` inside `onChange` closures (the
marquee froze and `ArtworkGlow` lagged a track that way; `PillMarqueeRenderTests` and
`ArtworkGlowRenderTests` render them).

**Motion vocabulary** ("fluid hardware extension"): every duration/curve/effect size lives in
`UI/PillMotion.swift` (`NotchAnimation.Motion` tokens, resolved by
`NotchAnimation.resolve(style:reduceMotion:)`) - don't hand-roll curves in a row. `.subtle` =
Fluid (default), `.dynamic` = Lively, `.minimal` and Reduce Motion share one token set (geometry
snaps, 120ms fades, no blur/scale/loop). `allowsGeometry` gates size/position effects,
`allowsPulse` one-shot symbol effects, `allowsLooping` the equalizer - the app's only perpetual
animation, which is why `musicIndicatorStyle` defaults to `.note`. Nothing may loop for ordinary
activity without opt-in, and blur is capped at 6pt and only during a reveal (also off under Reduce
Transparency). Structural and content motion have separate authorities:
- **Shape/container** (`PillExpansionPhase` choreography in `synchronizeExpansion`, generation-guarded
  so hover reversals retarget): open = shape springs (`shapeOpen`), wings shrink/blur out, then after
  `shapeLeadDelay` each section reveals via `PillRevealModifier` (opacity/scale/offset/blur,
  staggered by `PillSectionKind` rank; add new sections to that enum in stacking order, and to
  `hasSection`). The section stack is NOT built in one pass (that was a 30-90ms main-thread block at the
  start of every open): `mountSections` mounts it hidden a few sections per run-loop turn (`reveal`
  gates each section on `mountedThrough`), over `estimatedExpandedHeight` while the shape is already
  moving (Fluid/Lively) or with the shell held at the collapsed size (Minimal/Reduce Motion, which then
  snap open and fade the sections in one cheap pass, never showing an empty body); the reveal waits
  for the last stage. A one-shot `prewarmSections` pays first-use costs shortly after launch. Keep each
  stage cheap (no single run-loop turn much above one frame) and route every new section through
  `reveal(_:)`, which is what gates it on the stage. Close =
  sections fade together (`contentOut`), shape settles (`shapeClose`, critically damped) after
  `collapseShapeDelay`. `NotchShape` (concave top ear + bottom radius, both animatable, constants in
  `NotchGeometry`) is the one silhouette for fill, rim, clip and hit shape.
- **Layout**: expanded content is laid out at a constant width inside the animating, clipped
  container (content never sees an animated width). Only `PillStructuralAnimationState` owns section
  insert/remove animation; content replacement, polling refresh, direct manipulation and feedback
  stay scoped to their subviews; no broad `.animation` on the root.
- **Flash-open** (`PillFlashKind` via `flashOpen(kind:)`): sets hold time, spotlight section (reveals
  first, brief highlight, others start dimmed) and rim tint; finite and generation-guarded.
- **Panel**: the AppKit host never resizes during open/close - `NotchGeometry.contentFloor`
  (520x720, capped to the screen) covers every normal stack; `PillPanelSizingPolicy` only grows,
  quantized with headroom, and coalesces fractional overflow. Keep that separation.
- **Sections and wings** (`PillControls.swift`, `PillStyle.swift`, `WingIndicator.swift`): type scale,
  row heights and list caps (`PillTextStyle`, `PillRowHeight`, `PillLimits`) are tokens - nothing
  under 10pt; every row centres its icon in one `PillRowLeading.slot` so titles share a text column
  (title width caps subtract `PillRowLeading.titleInset`), lists capped so they never force a
  panel resize. Presses go through one
  `PillButtonStyle` with two roles: `.icon` (squeeze + dim, `press`/`release` overshoot) and `.row`
  (highlight only; a squeeze only in Lively). Rows animate as identity changes, not rebuilds: agent
  rows key on `AgentSession.identityKey` (`PillRowIdentity`), the timer is one persistent
  `PillTimerRing` across running/paused/completed (it steps once a second - `PillTimerRing.glides` only
  animates runs short enough to move 0.5pt/s, so none of the 5/15/25/50 min presets glide; no per-frame
  timeline), the notification row keeps identity and swaps leaves, the reminder row stays as a local
  "completing" snapshot for `completionHold`. Polling text updates carry `transaction { animation =
  nil }`; redacted strings crossfade on privacy toggles (opacity only, no blur). Wings are
  identity-keyed (`WingSelection`, pure and tested: one indicator per wing, swaps via `pillWing`),
  anchored `NotchGeometry.topEar` + `WingMetrics.inset(of:)` in from the outer edge (so the ear does not
  clip them and a narrow indicator keeps the same edge margin whatever the other wing shows; spare
  width opens toward the cutout). The mic/camera dots sit the same ~12pt from the visible edge. Attention is
  finite: `PillRipple` plays `attentionPulseCount` passes (0 under Reduce Motion = static tint +
  badge dot) and never loops, so an idle pill runs no animation. Haptics for section actions
  (tray drop, copy, reminder complete, privacy toggle) fire from the action; the only
  observer-driven one is `timerComplete`.
- **Accessibility and fallbacks**: every hold/delay/sweep is a `Motion` token (no raw durations in
  views; only values derived from a token or the 1 Hz tick may build an `Animation`, except the
  voice review countdown bar in `VoiceCountdownBar`: a determinate `.linear(duration: remaining)`
  taken from the countdown deadline, derived from neither a motion token nor `PillClock`). Translucent
  white surfaces go through `PillSurface.highlight` (opaque under Reduce Transparency, stronger under
  Increase Contrast) and every button carries `pillFocusRing` (one width/opacity, 2pt under Increase
  Contrast) - it draws only while the panel is key, and the non-activating panel never is, so the
  status menu stays the keyboard path (see Review-remediation notes). Do not make the panel key to
  "fix" this: a pinned key panel would take typing away from the frontmost app. `PillArrivalModifier` hides a transitioning view from VoiceOver at once and
  `.pillFade` replaces `.transition(.opacity)` on controls, so a leaving row/button is never read
  alongside its replacement; the expanded layer is `accessibilityHidden` until its reveal starts.
  Settings and onboarding use standard controls with `SettingsNote`/`SettingsHeader` (11pt notes,
  header trait); there is deliberately no separate "reduce motion in notch" setting - the Animation
  style plus macOS Reduce Motion already cover it. `PillSourceGuardTests` fails on `.onHover` or
  `repeatForever` anywhere in `UI/`.
- **Now playing** (`NowPlayingSectionView`, `NowPlayingControls`, `PillMarquee`): artwork accent
  (`ArtworkAccent`: 16x16 sample, dominant vivid hue lifted to >= 4.6:1 on black) is derived once per
  artwork bytes on the adapter queue inside `ArtworkCache`, stored on `NowPlayingInfo.accent` (excluded
  from `==`) and tints the progress fill, knob, equalizer and a static radial glow whose only
  animated property is opacity; privacy mode forces white and no glow, and the glow is off under
  Reduce Motion/Minimal and Reduce Transparency. A track change swaps leaf content only (title/artist
  `pillBlurSlide`, artwork crossfade keyed on image identity, never the row); the optimistic toggle in
  `NowPlayingController` is untouched, the glyph/art follow `info.isPlaying` immediately. The progress
  `TimelineView` runs at `PillProgressCadence` and only while expanded + playing + not scrubbing
  (scrubbing follows the pointer on `direct`). The title marquee (`MarqueePlan`) runs only while
  `expansionPhase == .expanded`, at most two passes, generation-guarded; the 4-bar expanded equalizer
  needs the opt-in `.equalizer` style. Haptics (`PillHaptics`) fire only from button/gesture
  callbacks. The volume readout is wing glyph + percent while minimized (never behind the cutout) and a
  chip while expanded. Measure widths with `GeometryReader` `onAppear`/`onChange`, not preference
  keys: preferences stopped propagating out of a subtree with branching content (headless render).

Agent row clicks resolve the *owning* host app via the agent process's cwd (`lsof`)
plus process ancestry (`ps`), not the first running terminal
(`AppActivation.owningHostPID`). Parsing/walking is pure and tested; the subprocess
helper shares one deadline and escalates to SIGKILL so it can never block, and the
newest click cancels any in-flight lookup. tmux/cmux ancestry doesn't reach a
terminal app, so those fall back to the old first-running-host guess.

v0.4.0 additions, one line each: rows are clickable (media → source app via
`bundleIdentifier`; agent → first running app in `AppActivation.agentHostBundleIDs`, else
reveal `AgentSession.projectPath` - a click-to-jump-only field, NEVER rendered); the
needs-you wing icon bounces on count change (macOS 14+ symbolEffect); `BatteryController`
(IOKit push notifications, plug/unplug flashes the pill open, nil state on desktops);
`UpdateChecker` (daily GitHub latest-release poll, status-menu item; inert in dev builds
with no bundle version; `isVersion(_:newerThan:)` is tested); `MediaUseMonitor` (push:
CoreAudio/CMIO "running somewhere" property listeners via `HardwareMediaUseSource`, 5s poll
only as the fallback if registration fails - these dots need no capture permission; the
microphone is requested only by opt-in voice control - orange mic/green
camera dots overlaid top-trailing on the shape); privacy mode (`privacyModeEnabled`,
default OFF, quick toggle in the status menu) follows the centralized
`NotchPillView.privacyRedacted` boundary above; tray drag-out uses
`NSItemProvider(contentsOf:)` (real Finder copies) and
QuickLook thumbnails cached in `TrayController.thumbnails`.

Review-remediation notes (2026-07-31), keep these invariants: `updateForScreenChange`
must ALWAYS call `applyPlacement` after the grow-only `resize` (the grow-only guard
alone leaves the panel at stale coordinates after a resolution/display change). The
status menu is rebuilt on every open (`StatusMenuBuilder.rebuildMenu`, via NSMenuDelegate) and
is the ONLY keyboard/VoiceOver path to media transport, agent jump, meeting join, reminder
completion/capture, clipboard, and tray - the panel itself is non-activating and never key, so keyboard
focus cannot reach it (its controls still carry button/label/adjustable semantics for VoiceOver when
pinned open); keep new pill actions mirrored there. Notification permission is requested at launch, not lazily (a lazy
request dropped the triggering notification). Scanner cwd/Codex-header facts are
cached in `AgentActivityScanner` (lock-guarded, nil results retried, cap-bounded), titles also
cache misses (`shouldRetryMissingTitle`), and turn state is cached per path under (mtime, size)
and pruned per scan - keep new derived-from-file facts behind those caches. Tail reads escalate
64KB -> 1MB -> 4MB until a turn signal is found, and header/head reads cut lines at the byte
level before decoding (never UTF-8-decode a raw prefix). Pi CWDs use that same immutable-fact pattern;
OpenCode query output is cached only while the `opencode.db` + WAL + SHM size/mtime signature is
unchanged (WAL/SHM-only changes are throttled to one query per `openCodeWALThrottle`), then
reclassified against the current time; the query is scoped to recently updated sessions and runs
through `SubprocessRunner` (timeout + output cap). Preserve that invalidation so the 5s scan
doesn't respawn SQLite against multi-gigabyte databases at idle. The agent publish signature
includes an elapsed-minutes bucket so row times/ordering refresh ~1/min. Calendar queries run off
the main actor (`queryNextEvent`) and permission is only requested once the feature is
enabled. Notification menu actions bind the app name they rendered through
`representedObject`; never retarget an already-open action to a newer `latest` banner.
CI (.github/workflows/ci.yml, macos-14 and macos-15) is where tests actually run.

Pill behavior/sizing is user-configurable via `SettingsStore` (Settings window):
`pillMode` (hover-auto vs always-expanded), `hoverCollapseDelay`, `minimizedWidth/Height`
(the synthetic cutout - real notch hardware always wins), `expandedWidth` (still floored
at cutout+wings via `NotchGeometry.expandedPillWidth`, which keeps the no-feedback-loop
fixed-width rule intact). All numeric knobs are clamped to their `SettingsStore.*Range`
bounds on read AND write - keep new knobs on that pattern. Tests:
`SettingsStoreTests.swift` (isolated UserDefaults suite; runs under Xcode/CI only).
Stored keys live in the `SettingsStore.Key` enum: raw values are the on-disk names and must never
be renamed. A change to a stored value's meaning bumps `currentSchemaVersion` and adds an
idempotent step to `SettingsStore.migrations`. Settings export/import (`SettingsTransfer.swift`)
is an explicit allowlist (`transferFields`): preferences only, never muted-app names, the pill
display id, onboarding state, or any feature content; a new preference is exported only if it is
added there. `checkForUpdates` (default ON) gates every `UpdateChecker` request; `pillDisplay`
(`automatic` or an opaque display id) is stored but machine-specific and not exported. Launch at
login is `LaunchAtLogin` (shared by the status menu and Settings; `.requiresApproval` is surfaced,
not treated as off). Controllers that observe a flag take an injectable `settings:` store.
The one-time `OnboardingView` is a separate activating window so it never changes pill geometry;
it contains no live user content or permission prompts and remains reopenable from Settings/menu.

## Voice control (`Sources/DesnotchCore/Voice/`)

Off by default (`SettingsStore.voiceEnabled`). Holding the talk shortcut (`VoiceHotkeyChoice`,
default Option-Command-V) drives `CarbonPushToTalk` into `VoiceCoordinator`, which runs the pure
`VoiceReducer` and applies its effects: on-device `AppleSpeechRecognizer` (audio stays in the
process), `SystemLocalExecutor` for the closed local grammar, or, when the second opt-in is on,
`HermesAgentBackend` speaking ACP over stdio to a `hermes -p voice acp` child. `VoiceSessionModel`
is what the pill, wings, status menu, and Settings read. The flow, tiers, and rule table are
`docs/voice/PLAN.md`.

**Opt-in AI provider** (`Voice/OpenAI/`, Settings section `VoiceAIProviderSettingsSection`): per step,
`voiceSpeechProvider` (on-device | OpenAI-compatible `OpenAISpeechRecognizer`), `voiceAnswersProvider`
(Hermes | OpenAI-compatible | Anthropic, all through `VoiceChatBackend` except Hermes, with the lane
switch still `voiceHermesLane`) and `voiceReplyProvider` (macOS | OpenAI-compatible
`OpenAISpeechSynthesizer`, falling back to the macOS voice). Defaults keep today's behavior. The
coordinator picks the recognizer at capture start and the backend at submit (`VoiceAIProviders`, nil
in tests and smoke mode); the provider lane reuses the reducer's `.hermes` lane, so the review window,
R54, the daily cap, Stop and the audit apply unchanged. `VoiceAIHTTP` is the only network path:
ephemeral session, redirects refused, https except loopback (`VoiceAIEndpoint`). Keys live only in
the Keychain (`KeychainVoiceAIKeyStore`, one service per provider); never in `SettingsStore`, logs,
export, audit or any UI text. A cloud capture is uploaded only when the user ended it (a cap-ended one
fails `needsUserRelease`), its final watchdog is stretched to `VoiceAILimits.transcriptionWatchdog`,
and `VoiceSessionModel.cloudActivity` drives the cloud mark.

**Machine control** (`Voice/Tools/`, opt-in `voiceAgentToolsEnabled` "Let the agent control this Mac",
shown only for the OpenAI-compatible/Claude answers; the Hermes lane is unchanged and still tripwired).
`AgentToolbox` (the v1 catalog behind `ChatToolHandling`) runs tools IN-PROCESS, so `AgentToolGate`
classifies every call BEFORE it starts: T0/T1 run with a step chip (T1 rate-limited), T2 raises
`.approvalNeeded` (hold-to-approve card with the exact command/path/URL, nonce-bound, one card per call)
and starts only on `respond(nonce:allow: true)`, T3/T4 and unknown tools never run (R84). Starts are
reported with `AgentToolStep` labels, which `ToolTierTable` resolves exactly (R82t; Hermes kinds can never
match them). Shell/AppleScript tiers come from `CommandRiskScanner` (never below T2; do not add a second
pattern list), paths from `AgentToolPaths` (protected markers before and after symlink resolution are T4;
reads quiet only in home outside dotfolders and `~/Library`; writes elsewhere are T3), URLs from
`AgentURLPolicy` (local/private/tailnet hosts T3; query/credentials/long URLs T2). Processes go through
`SubprocessRunner` (own group, sanitized env, scratch cwd, 30 s, 16 KB) and die with the turn task on Stop.
`web_fetch` is the one extra network path and lives in `Voice/OpenAI/AgentWebFetcher.swift` (URLSession
stays in that folder). Tool output is capped and fenced as untrusted; the audit gets one metadata-only
record per call (`tool.<name>`, tier, outcome code, duration). Keep every new tool on that pattern: a
`propose` without side effects, an `execute` that re-checks, a label in `AgentToolStep.tiers`, and tests
in `Tests/DesnotchCoreTests/Voice/Tools/` against a temporary folder, never the real machine.

The expanded pill also has a **Talk row** (`TalkRowPresentation`, `NotchPillView+TalkAction.swift`, `PillSectionKind.talk`):
shown only while voice is enabled, idle, and `voice.actions.toggleTalk` is installed (never in smoke-test mode); it calls
`toggleTalk()` (R11/R33), or `requestPermissions()` while access is `.notDetermined`. The listening card carries Cancel, Done
(`toggleTalk`) and Stop. Keep the row non-activating and hidden whenever the voice section is up.

`Contracts/` is frozen. The other folders are `Logic/` (reducer, router, tiers), `Platform/`
(speech, hotkey, permissions, audit), `Coordinator/`, `Hermes/` (preflight, ACP, process
guard), `OpenAI/` (opt-in AI providers) and `Tools/` (opt-in machine control). Put a change in the folder
that already owns that layer.

Load-bearing privacy rules (all 12 are `docs/voice/PLAN.md` section 14):

- Audio is never written to disk. Recognition is on-device by default; a locale without on-device
  support fails closed (no silent server fallback). Only when the user picks an AI provider for a
  step does that step's audio or text leave the Mac, only to the configured base URL, with the
  cloud mark showing, and nothing is persisted (PLAN section 14 rule 1).
- Utterance, reply, and command text stay out of logs, the audit log, VoiceOver, and the status
  menu. A local approval shows a desnotch-authored summary. The audit log stores metadata only
  (hashes and codes).
- Approvals are visual only, bound to a random nonce, and answered once or deny. T3 is denied
  in the MVP. T4 has no voice path.
- Tools are default-deny, plus a tripwire. The profile's ACP toolset is empty. A Hermes tool at T2
  or higher trips the wire; a tripwire pause is the normal outcome of a Hermes tool call. The
  in-process machine-control tools (opt-in) ask for the card before they start instead, and
  nothing a tool returns can approve a card.
- Stop is total (interrupt, then SIGTERM and SIGKILL on the agent's process group). desnotch
  signals only processes it spawned. Crash recovery of a stale pid file also requires the
  command-line tokens `-p voice acp`, a matching start time, and a group leader
  (`HermesProcessGuard`).
- This feature's permissions are Microphone and Speech Recognition, requested only after the
  user enables voice and presses Allow. It does not take Accessibility, Screen Recording, or Full
  Disk Access. With machine control on, the first approved AppleScript that targets an app shows
  the macOS Automation prompt (`NSAppleEventsUsageDescription`, apple-events entitlement).
- Voice is off by default and inert in smoke-test mode.
- The human creates and locks the Hermes profile `voice`. desnotch only reads
  `~/.hermes/profiles/voice/config.yaml`. Never edit `~/.hermes`.
- Hermes retains its own transcripts in its `state.db`. The desnotch audit log is metadata only.
- Harness: `scripts/voice-harness/run.sh` and `scripts/voice-harness/lint-lite.sh`. The warning
  check (fresh harness directory, path-prefixed diagnostics) is in `docs/voice/PLAN.md` section 12.
- `voiceEnabled` stops the feature at runtime. Removing it from the tree is `docs/voice/PLAN.md`
  section 17.

## App wiring (`Sources/DesnotchCore/App/`)

`AppDelegate` (`@MainActor`) is only the single-instance guard plus launch/terminate sequencing.
`AppComposition` owns every controller and their wiring (the update checker, the global hot key,
the voice coordinator, and the Hermes backend are nil in smoke-test mode; `voiceModel` still
exists and nothing drives it); `WindowCoordinator` owns the notch panel's `NotchWindowController` (hover authority
stays there) and the lazily created Settings / Getting Started / Add Reminder windows;
`StatusMenuBuilder` (+ `StatusMenuBuilder+Actions.swift`) owns the status item, the rebuild-on-open
menu, and every menu action handler. New controllers go in `AppComposition`; new menu actions need a
`#selector` in `StatusMenuBuilder` and a handler in the `+Actions` extension.

## Build/run

See `README.md` for `swift run`/`swift build` and `scripts/build-app.sh` (release build + minimal
`.app` bundle + inside-out codesign verified with `--deep --strict`; ad-hoc by default, Developer
ID/notarization opt-in). `HARDENED_RUNTIME=1` signs the main executable and app with
`scripts/desnotch.entitlements` (calendars, so EventKit is not denied silently, and
`com.apple.security.device.audio-input`, so the microphone is not denied) and fails if the file is
missing. The Info.plist that script writes includes `NSMicrophoneUsageDescription` and
`NSSpeechRecognitionUsageDescription`. `VERSION` comes from the environment or the latest git tag and the build
fails without either. The vendored adapter is pinned by `VENDOR.sha256` (verified before and
after bundling). `CONTRIBUTING.md` covers build/test/lint (XCTest only runs in CI), and
`RELEASING.md` the tag-driven `release.yml` flow. No Xcode project - SPM executable target only.
`CLAUDE.md` is a symlink to this file: edit `AGENTS.md` only.

Homebrew distribution lives in `https://github.com/Veyal/homebrew-desnotch`
(`Casks/desnotch.rb`). A release is not complete until that cask points at the published
`desnotch-v<version>-universal.zip` with its exact SHA-256; users depend on
`brew upgrade --cask desnotch`. Validate with `brew style`, strict/online `brew audit`,
`brew livecheck`, and a real cask install/upgrade. While releases remain ad-hoc signed, keep the
tap's transparent Gatekeeper caveat; never disable quarantine or recommend removing its metadata.
Official `homebrew/cask` submission waits for a Developer ID-signed, notarized artifact.

`scripts/permission-status.sh` executes the packaged binary with `DESNOTCH_PERMISSION_PROBE=1`
to print Accessibility/Calendar/Reminders state without prompting or starting the app. Its inline caveat
about responsible-process attribution is authoritative; use `REQUIRE_GRANTED=1` only after
verifying the normally launched app has its core grants, and `REQUIRE_REMINDERS_GRANTED=1` only
when the opt-in Reminders feature is expected to be authorized.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
