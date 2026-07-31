# Changelog

## v0.4.2 — 2026-07-31

- ✓ **Fix: stale "now playing" rows from browser tabs** (e.g. "(5) WhatsApp" showing an
  audio player with nothing playing). Browser media sessions are never unregistered
  while the tab lives, so residue lingered in the pill for hours. Non-playing items
  with sub-second durations (notification pings) are now filtered outright, and any
  paused session expires from the pill 15 minutes after its last position change.
  Playing media is never hidden and never expires; pause/seek keep the timeline
  position continuous. Regression-tested against the observed WhatsApp Web payload.

## v0.4.1 — 2026-07-31

Full remediation of the comprehensive product review:

- ✓ **Fix: pill left at stale coordinates after display/resolution changes** - screen
  changes now always re-anchor the panel (`applyPlacement`), independent of the
  grow-only resize guard.
- ✓ **Keyboard/VoiceOver access**: the status menu rebuilds on every open and mirrors
  the pill - now-playing transport, jump-to-agent, and a Tray submenu - since the
  non-activating panel can't be focused by assistive tech. Also fixes stale checkbox
  states when settings change elsewhere.
- ✓ **Fix: first needs-you notification was dropped** - notification permission is now
  requested at launch instead of lazily at first delivery.
- ✓ **Fix: frozen agent row times/ordering** - publish signature includes an
  elapsed-minutes bucket, so rows refresh ~1/min.
- ✓ **Calendar queries moved off the main actor**; calendar permission is requested
  only when the feature is enabled (including later enablement).
- ✓ **Scanner caches immutable per-file facts** (task title, cwd, Codex header) instead
  of re-parsing up to ~1MB per session every 5s.
- ✓ **Volume scroll passes through** when the output device has no settable volume.
- ✓ **Mic dot ignores virtual/loopback audio devices** (BlackHole & co.).
- ✓ **Privacy mode scope made explicit and extended** to now-playing title/artist and
  tray filenames; Settings describes the exact scope; the menu mirror honors it.
- ✓ **Media durations over an hour** format as h:mm:ss (`TimeFormatting`, tested).
- ✓ **Update badge**: visible orange dot on the status icon instead of a glyph swap.
- ✓ **CI**: GitHub Actions (macos-14) runs `swift build` + `swift test` on push/PR -
  the first environment where the test suite actually executes.
- ✓ **Tests**: clock formatting, task-title sanitization rules, now-playing timestamp
  parsing and position extrapolation. Support types split into `NotchPillSupport.swift`.

## v0.4.0 — 2026-07-31

The pill becomes actionable:

- ✓ **Click-to-jump**: media artwork/title activates the playing app; an agent row
  activates your terminal/editor (first running of iTerm2/Ghostty/Warp/Terminal/Cursor/
  VS Code), or reveals the project folder when none is running.
- ✓ **Needs-attention pulse**: the wing bolt icon bounces when the needs-you count
  changes (macOS 14+).
- ✓ **Battery glance** (MacBooks): percent + charging row; plugging/unplugging briefly
  auto-expands the pill. Hidden on desktops. Toggleable.
- ✓ **Update check**: daily GitHub release poll; an "Update Available (x.y.z)…" item
  appears in the status menu (update via `brew upgrade --cask desnotch`).
- ✓ **Mic/camera in-use dots**: orange (mic) / green (camera) dots on the shape's
  top-right when any process uses them; no capture permission needed. Toggleable.
- ✓ **Privacy mode** (Settings toggle + status-menu quick toggle, default off): blanks
  agent task titles (→ project name) and calendar titles (→ "Busy") for screen sharing.
- ✓ **Tray upgrades**: Finder-grade drag-out (real file copies), QuickLook thumbnails
  for previewable files, batch drops.

## v0.3.4 — 2026-07-31

- ✓ **Configurable notch panel** (Settings → "Notch panel"): visibility mode ("Open on
  hover" vs "Always expanded"), hover collapse delay (0.1–5s, default 0.4s), minimized
  cutout size (width 120–400pt / height 24–44pt; notch-less screens only - real hardware
  wins), and expanded width (260–480pt, still floored at cutout+wings via
  `NotchGeometry.expandedPillWidth`). All knobs UserDefaults-persisted and clamped to
  bounds on read and write.
- ✓ **Tests**: `SettingsStoreTests` (defaults, persistence roundtrip, clamping, mode
  fallback, expanded-sizing floor) against an isolated defaults suite (Xcode/CI only).

## v0.3.3 — 2026-07-30

- ✓ **Always-visible notch.** The notch renders even with nothing active (invisible
  black-on-black on real hardware) - hover always works and hosts the calendar glance +
  the new file tray.
- ✓ **File tray** with full drag feedback: drag files onto the notch (shape highlights,
  pill expands, "Drop to add" state), items animate in, click opens, drag out re-exports,
  ✕ removes. Path references persist across launches (8 max).
- ✓ **Fix: pill collapsed ~1s into a hover.** SwiftUI `.onHover` raced panel resizes;
  hover is now owned solely by the window controller's cursor tracker.
- ✓ **Fix: hover at the absolute top of the screen didn't register** (NSRect top-edge
  exclusion vs. a top-pinned cursor reporting exactly y == screen top).
- ✓ **Now-playing timeline**: thin progress bar + elapsed/total, extrapolated client-side,
  1s tick only while visible; hidden for sources with no duration.
- ✓ **Settings pane** (menu bar icon → Settings…, ⌘,): per-feature toggles (now playing,
  agents, calendar, process detector, tray, volume scroll, notifications). Disabled
  features stop their background work, not just their UI.
- ✓ **Calendar glance**: lookahead 12h → 24h with day-aware labels ("in 42m", "14:00",
  "tmrw 09:00"); a denied-access state now shows a clickable hint row instead of nothing.

## v0.3.2 — 2026-07-30

New pill sections & gestures:

- ✓ **Grow-from-notch animation.** Minimized/expanded are now one continuous black shape
  (`notchBody`) whose frame + corner radius morph under the spring; only the content
  cross-fades (clipped to the growing shape). No more shrink-then-grow double shape.
- ✓ **Agent task titles.** Rows show a hint of what each agent is doing - derived from the
  session's first prompt line, hard-capped at 48 chars (Claude Code + Codex; others fall
  back to the project folder name; project name on hover tooltip).
- ✓ **Volume on scroll** over the pill (CoreAudio `VirtualMainVolume`) with a brief level
  bar readout.
- ✓ **Needs-you notifications** when an agent newly flips to needs-your-turn (packaged app:
  user notification; bare binary: sound). Toggle in the status-bar menu.
- ✓ **Calendar glance**: next non-all-day event within 12h as an expanded row; keeps the
  pill alive on its own when starting within 30 min or ongoing. Calendar permission is
  requested on first launch.
- ✓ **Stuck-process detector**: flags processes sustaining ≥90% CPU for ≥10 min (orange
  flame section + one notification per streak, top 3 by CPU).
- ✓ **Fix: 1px wallpaper hairline** above the pill (fractional window frame; now integral,
  flush with the screen top).
- ✓ **Fix: menu-bar clicks swallowed** near the notch: the panel is click-through except
  while the cursor is inside the pill's current visual rect (cursor-tracked
  `ignoresMouseEvents`).

## v0.3.1 — 2026-07-30

- ✓ **Notch-less screens now replicate the MacBook notch exactly.** The old fallback (a
  capsule floating below the menu bar) is gone: every screen renders the same
  wings-around-cutout layout via `NotchPillView.effectiveNotch` - a real hardware cutout on
  notch screens, a synthetic MacBook-sized one (`fakeNotchSize`, 200×30pt of plain black)
  drawn over the menu bar top-center on notch-less screens. Panel is anchored flush with the
  screen top everywhere; expanded content sits below the cutout in both cases.

## v0.3.0 — 2026-07-29

Physical-notch compatibility (reported on a MacBook Pro 14" M2 Pro: the minimized pill was
invisible behind the camera housing) and expanded-width fixes:

- ✓ **Never draw behind the cutout.** New `NotchGeometry.notchSize(for:)` measures the
  hardware cutout from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`. On a notch screen the
  minimized pill is now a solid-black, bottom-rounded extension of the notch with the
  indicators in 44pt "wings" either side of the cutout; the expanded pill keeps the same
  flush shape and pushes all content below the cutout. Solid black fill blends with the
  hardware. Notch-less screens keep the previous floating capsule/pill.
- ✓ **Expanded pill no longer opens too wide.** The rows contain greedy `Spacer`s, so the
  pill silently filled the whole panel (content floor, 340pt+). It now has a fixed 300pt
  width (at least cutout + wings on a notch screen), the content floor is 300pt, and the
  title/project labels have tighter `maxWidth` caps (140/150pt) with truncation.
- ✓ **Stale docs corrected.** `NotchPillView`/`NotchPillPresentation` headers and
  `AGENTS.md` described the removed toast/auto-expand model and pre-split
  `Sources/desnotch/` paths; both now match the hover-only behavior and notch layout.

---

# v0.2.0 TODO review

Work performed against `TODO.md` (2026-07-29 review) on the `main` branch. Each TODO
item is marked **Done**, **Partial**, or **Deferred** with rationale. All code changes
build clean (`swift build`, zero warnings/errors); the release bundle
(`scripts/build-app.sh`) builds, codesigns, and launches end-to-end, and SIGTERM cleanup
of the perl adapter was verified at runtime.

Notation: ✓ = Done, ~ = Partial, ✗ = Deferred (needs hardware / external sign-off / owner
decision).

---

## Cluster 1 — "safe to leave running" (critical)

- ✓ **Invisible panel no longer eats menu-bar clicks.** Hidden branch is
  `.allowsHitTesting(false)`; visible content uses `.contentShape(Capsule())` so only the
  capsule takes clicks/hover; `NotchWindowController` drives `panel.ignoresMouseEvents` from
  real content presence via a Combine pipeline over both controllers. (`NotchPillView.swift`,
  `NotchWindowController.swift`)
- ✓ **Expanded pill no longer clipped.** Content size is reported through a
  `GeometryReader` preference to the panel owner, which resizes the `NSPanel` to fit
  content + shadow/overshoot insets (sides 12pt, bottom 16pt) instead of a fixed 300×44.
  Also fixes the headline-overflow and shadow-room items in clusters 3/5.
  (`PillContentPreferenceKey.swift`, `NotchPillView.swift`, `NotchGeometry.swift`,
  `NotchWindowController.swift`)
- ✓ **App is quittable.** Added an `NSStatusItem` (menu bar icon) with a Quit menu item and
  a Launch-at-Login toggle, since the borderless panel can't become key. (`AppDelegate.swift`)
- ✓ **`pkill`/SIGTERM no longer orphans the perl adapter.** `main.swift` installs
  `DispatchSourceSignal` handlers for SIGTERM/SIGINT → `stopStreaming()` + `exit(0)`
  (with the signals ignored first). Verified at runtime: after `pkill -TERM desnotch`, both
  the app and the adapter subprocess exit. README's "pkill" guidance updated.

## Cluster 2 — media bridge resilience

- ✓ **stderr pipe deadlock fixed.** `stream` uses `FileHandle.nullDevice` for stderr (was an
  undrained `Pipe` whose 64 KB buffer could freeze the single-threaded adapter).
- ✓ **Stream auto-restarts.** `terminationHandler` relaunches with exponential backoff
  (1s→30s cap) on a private serial queue, guarded by an `isStopping` flag set by
  `stopStreaming()`.
- ✓ **All failure paths log.** `os.Logger` (`com.desnotch.app`, category `MediaRemote`) at
  `.error`/`.notice`/`.info` for missing resources, launch failure, JSON parse failure,
  send/get failure, and recovery. (No more silent death.)
- ✓ **Data races removed.** All mutable stream state (`streamProcess`, `stdoutBuffer`,
  `isStopping`, `restartAttempt`) is touched only on one serial `DispatchQueue`
  (`desnotch.mediaremote`); the readability handler routes through it. Addresses the
  strict-concurrency / Swift-6 warnings.
- ✓ **Failed play/pause reconciled.** `NowPlayingController.scheduleReconciliation()` runs a
  one-shot adapter `get` (`MediaRemoteBridge.getOnce`) ~1.5s after a transport tap if the
  stream hasn't confirmed the new state, and applies it as ground truth. New bridge
  `getOnce(completion:)` added.
- ✓ **Transport taps debounced/coalesced.** Toggles within ~250ms are coalesced locally
  instead of spawning overlapping perl `send` processes; optimistic state stays consistent.
- ✓ **Artwork decoded once + downsampled.** `ArtworkCache` (NSCache, keyed on
  `uniqueIdentifier`/blob-prefix) downsampled to ~128px via `CGImageSourceCreateThumbnail`,
  so re-deliveries don't re-decode a ~1 MB blob. Stream launched with `--debounce=100`.
- ✓ **`NSNull` no longer yields `"<null>"`.** `uniqueIdentifier` coercion handles
  String/NSNumber/NSNull/empty explicitly.
- ✓ **`bundleIdentifier` participates in equality** so a same-title track in a different
  app (or identifier-less sources) is detected as a real change.

## Cluster 3 — agent-activity accuracy

- ✓ **Codex detection no longer 100% dead.** `firstLine` is replaced by `readUpToNewline`
  which reads until the first newline (up to 1 MiB). Real Codex `session_meta` headers
  (~22 KB; verified on this machine) used to exceed the 4 KB read and dropped every session.
- ~ **Dead sessions no longer reported "stalled" for up to 2h.** Tightened with a
  `stalledSessionMax` (45 min) cap: a presumed-hung session with no file change past 45 min
  is dropped, not surfaced as stalled. The **authoritative `~/.claude/sessions/<pid>.json`
  redesign (pid liveness / status / cwd as primary source)** is ✗ Deferred — that directory
  is empty on this machine, so the schema can't be validated; the JSONL path (now correct)
  remains the workhorse. Implement once a real sample exists.
- ✓ **Dashed project names no longer mangled.** Claude labels now come from the real `cwd`
  in the transcript header (`readClaudeCWD`), so `acme-app` stays whole instead
  of collapsing to `tracker`; falls back to the encoded name only if `cwd` is absent.
- ✓ **Summary stops republishing every 5s forever.** `AgentActivitySummary` is now
  `Equatable`; `AgentActivityController.apply` guards the publish on inequality.
- ✓ **Giant single JSONL entry no longer drops a session.** `tailLines` escalates the seek
  window (64 KiB → 1 MiB → 4 MiB) until a line boundary is found.
- ✓ **Tail seek no longer splits a UTF-8 char.** The read is trimmed to the first newline at
  the **byte** level before UTF-8 decoding, so a multibyte char split by the seek offset
  can't fail the decode.
- ✓ **Scans no longer overlap.** Replaced the repeating timer with a single
  `Task.detached { while !Task.isCancelled { scan(); sleep } }` loop.
- ✓ **Headline overflow** — fixed by the content-driven window sizing (cluster 1).

## Cluster 4 — behavior/UX correctness

- ✓ **Paused media no longer suppresses agent activity forever.** New `contentKind`
  (`PillContentKind`): now-playing wins while *playing* or expanded; paused/stopped media
  *yields* to agent activity. When paused with no agents, a collapsed now-playing indicator
  remains so the user can resume. (This also resolves the cross-cutting CLAUDE.md note:
  `contentKind` now actually exists.)
- ✓ **Agent pill is a toast, not a persistent panel.** Expand/collapse/hover logic lifted
  into a shared `NotchPillPresentation`, used by both content modes; agent content has its
  own collapsed indicator + expanded headline.
- ✓ **Artist line legible in Light Mode.** `.environment(\.colorScheme, .dark)` on the pill
  root (it's always an dark capsule).
- ~ **Hover latch intent.** Hover is now gated on `contentKind != .hidden` and the
  capsule-only `contentShape`. Requiring an actual mouse-move delta (vs. an auto-expand
  under a stationary cursor) is ✗ Deferred — SwiftUI's `.onHover` already fires only on
  enter; the residual edge case is minor.
- ✓ **Timers run in `.common` run-loop mode** (auto-collapse, hover-exit, reconciliation)
  so they keep firing during menu tracking.
- ✓ **Pill anchors to a notch screen** (`NotchGeometry.preferredScreen()` prefers a screen
  with `safeAreaInsets.top > 0`, else main) rather than following keyboard focus
  (`NSScreen.main` alone).
- ✓ **Display plug/unplug updates notch geometry.** `hasPhysicalNotch` is re-evaluated on
  `didChangeScreenParametersNotification` and the hosting view is rebuilt when it changes.
- ~ **Real-notch collapsed-dot rendering inside the cutout / dead `max(gap,300)` math.**
  ✗ Deferred — needs verification on a physical MacBook; non-notch path is correct and is
  what's exercised here.
- ✓ **Non-notch fallback sits fully below the menu bar** (`y = visibleFrame.maxY - h - 6`)
  instead of straddling it.
- ~ **Pill over fullscreen video/presentations.** ✗ Deferred by design —
  `fullScreenAuxiliary` keeps the live activity visible over fullscreen, which is the
  intended notch-app behavior. Revisit if a "hide in fullscreen media" preference is wanted.
- ✓ **No-display launch retries.** If no screen exists at launch, the window is created on
  the first `didChangeScreenParametersNotification`.

## Cluster 5 — animation & polish

- ~ **Morph vs. cross-fade (`matchedGeometryEffect`).** ✗ Deferred — the collapsed↔expanded
  swap still uses a scale+opacity transition; a true artwork morph is the biggest remaining
  feel upgrade but a larger view refactor. Other polish below is done.
- ✓ **Play/pause symbol transition** (`.contentTransition(.symbolEffect(.replace))`, macOS
  14+, guarded for the 13 min target).
- ✓ **Numeric text transition** for agent counts (`.numericText()`, macOS 14+, guarded).
- ✓ **Button press/hover feedback** (`PillButtonStyle`) + 24×24 targets + `.contentShape` —
  important given the ~1s command round-trip.
- ✓ **Reduce Motion** honored (spring/scale → short fade); transitions swap to `.opacity`.
- ✓ **VoiceOver labels** on transport buttons, combined title/artist element, decorative
  artwork/indicators hidden.
- ✓ **Material/placeholder/tooltips.** Music-note placeholder for missing artwork; `.help()`
  tooltips on controls; shadow room via panel insets.
- ✓ **`.stalled` distinguished visually** (orange `exclamationmark.triangle.fill`).
- ~ **Shape/material against a real notch** (flat-topped `UnevenRoundedRectangle`, opaque
  black) — ✗ Deferred until tested on real notch hardware.

## Cluster 6 — packaging, structure, tests

- ✓ **Bundle is notarizable.** Adapter now ships under `Contents/Resources/MediaRemoteAdapter`
  (codesign-sealed), resolved via `Bundle.main.resourceURL` with `Bundle.module` as the
  `swift run` fallback (`MediaRemoteBridge.locateAdapter()`). Verified both paths launch the
  adapter at runtime. Removes the `fatalError`-on-missing-bundle and embedded dev path; the
  stale "fails silently / .app-root" note in AGENTS.md/CLAUDE.md corrected.
- ~ **Universal build** — ✗ Deferred (needs a cross-arch toolchain validation); the
  signing changes are done.
- ✓ **Inside-out signing, `--deep` dropped** (`build-app.sh`): framework → binary → bundle.
  `--options runtime`/`--timestamp` intentionally omitted (need a Developer ID, not ad-hoc).
- ✓ **Single-instance guard** (`NSRunningApplication` by bundle id).
- ✓ **Launch-at-login toggle** (`SMAppService.mainApp`) in the status item menu.
- ✓ **`DesnotchCore` library target split**; `desnotch` executable is a thin `main.swift`
  shim (`import DesnotchCore`). Feature-folder layout preserved.
- ~ **Tests** added for the pure/testable logic (priority-ordered in the TODO):
  `AgentActivityScanner.classify` (incl. the new stalled-drop cap);
  transcript parsing against fixtures (Codex >4 KB header not dropped, Claude cwd-label
  recovery, subagent/automation skip, tail-window escalation, multibyte content);
  `AgentActivitySummary.headline`/`Equatable`;
  `NowPlayingInfo(adapterPayload:)` graceful degradation + `NSNull` handling;
  `MediaRemoteBridge.payload` parsing. **Note:** `swift test` requires Xcode (XCTest); this
  machine has only Command Line Tools, so tests are written/reviewed but not executed here
  — run under Xcode or CI.
- ✓ **Hygiene:** `.DS_Store` in `.gitignore`; root `NOTICE.md` (mediaremote-adapter BSD-3,
  agent-island MIT attribution); version from `git describe --tags` in `build-app.sh`.
- ~ **Deferred hygiene (owner decisions):** top-level `LICENSE` (license choice is yours);
  app icon; "real" bundle id (com.desnotch.app isn't a domain you control — left unchanged
  rather than guessed); CI workflow.

## Cross-cutting notes

- ✓ `CLAUDE.md`/`AGENTS.md` reference to `NotchPillView.contentKind` is now accurate (the
  computed property + `PillContentKind` enum exist).
- ✓ Strict-concurrency: the 6 `MediaRemoteBridge` warnings are resolved (serial-queue
  funnel); `swift build` reports zero warnings/errors.
- ~ UI reviewer measurement probes (`sizeprobe.swift`, etc.) live in a session scratchpad,
  not the repo — not re-run here (content sizing is verified by the build/launch, not pixel
  measurement).

## Verification performed

- `swift build` — clean, no errors/warnings.
- `scripts/build-app.sh` — release build + bundle + inside-out codesign; `codesign --verify
  --strict` passes; structure has adapter under `Contents/Resources`.
- Runtime: launched both `dist/desnotch.app` (adapter resolves from `Contents/Resources`) and
  `swift run` (adapter resolves from the SPM `DesnotchCore` bundle); both spawn the stream
  subprocess with `--debounce=100`.
- `pkill -TERM desnotch` exits the app **and** the perl adapter cleanly (no orphan).
