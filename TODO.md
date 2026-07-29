# TODO — findings from full review (2026-07-29)

Four-agent review (UI/UX, media pipeline, agent-activity, build/completeness), all findings
verified by probes on this machine (hit-testing a real panel, SwiftUI layout measurement, live
adapter runs, parse simulation against real session files). Build passes clean. Ordered by
suggested attack order; items within a cluster are roughly independent.

## Cluster 1 — "safe to leave running" (critical, every user, every launch)

- [ ] **Invisible panel eats menu-bar clicks.** `Color.clear` is hit-testable and the panel sits
  above menu-bar level, so a permanent 300×44 dead zone straddles the menu bar even with nothing
  shown. Fix: `.allowsHitTesting(false)` + shrink the hidden branch (`NotchPillView.swift:37-39`),
  drive `panel.ignoresMouseEvents` from "has any content" (`NotchWindowController.swift:32`), add
  `.contentShape(Capsule())` so only the capsule takes clicks/hover.
- [ ] **Expanded pill is clipped everywhere.** Window hardcoded 300×44; real content measures
  318×51 (capsule squashed, titles truncate ~11% early, no room for shadow/overshoot).
  Fix: report content size via GeometryReader preference; animate `panel.setFrame` in sync with
  the SwiftUI spring (`NotchWindowController.swift:10`, `NotchPillView.swift:77-108`).
  Stopgap: bump to ≥380×72 (but that widens the dead zone — do together with the item above).
- [ ] **App is unquittable.** Accessory policy + borderless non-activating panel can never become
  key → Cmd+Q menu in `main.swift` is dead code; only exit is `pkill`. Fix: `.contextMenu`
  Quit on the pill and/or an `NSStatusItem`.
- [ ] **`pkill` orphans the perl subprocess.** `applicationWillTerminate` doesn't run on SIGTERM.
  Fix: `DispatchSourceSignal` for SIGTERM/SIGINT in `main.swift` → `stopStreaming()` + `exit(0)`
  (remember `signal(SIGTERM, SIG_IGN)` first). Then fix README.md:29 which recommends `pkill`.

## Cluster 2 — media bridge resilience (silent-death paths)

- [ ] **Unread stderr pipe can deadlock the stream.** `MediaRemoteBridge.swift:63` creates a Pipe
  never drained; 64 KB of perl stderr blocks the single-threaded adapter forever → now-playing
  freezes silently. Fix: `FileHandle.nullDevice` (like `send` at :105) or drain+log.
- [ ] **No restart if the stream dies.** No `terminationHandler`; one perl crash kills now-playing
  for the app's lifetime (`MediaRemoteBridge.swift:54-73`). Fix: terminationHandler → restart with
  exponential backoff (1s→30s cap) on a private serial queue, guarded by an `isStopping` flag.
- [ ] **Every failure path is silent.** Missing resources, `run()` failure, JSON parse failure,
  `send` failure — zero logging (`MediaRemoteBridge.swift:55,71,88-91,106`). Fix: `os.Logger`
  (subsystem `com.desnotch.app`) at `.error` on each path. Do this first — makes the rest diagnosable.
- [ ] **Data races on bridge state.** readabilityHandler queue vs main both touch
  `streamProcess`/`stdoutBuffer`; strict-concurrency flags it (Swift 6 errors). Fix: funnel
  start/consume/stop through one private serial DispatchQueue. Needed before the restart logic.
- [ ] **Failed play/pause leaves UI permanently wrong.** Optimistic flip + dropped command + change-
  driven stream = no correction ever arrives. Fix: if no stream update ~1.5s after a toggle, run
  adapter `get` once and apply as ground truth (`NowPlayingController.swift:100-105`).
- [ ] **No debounce on transport taps** — rapid taps spawn unbounded perl processes and desync the
  optimistic state. Serialize sends; coalesce toggles within ~250ms.
- [ ] **~1.2 MB artwork re-decoded on every update** (even play/pause flips), never downsampled for
  a 16/24pt view. Fix: pass `--debounce=100` to the adapter, cache decoded artwork keyed on
  `uniqueIdentifier`+mime, downsample to ~64×64@2x (`MediaRemoteBridge.swift:59`,
  `NowPlayingInfo.swift:39-45`).
- [ ] **`NSNull` → literal `"<null>"` uniqueIdentifier** breaks track-change equality
  (`NowPlayingInfo.swift:37`). Fix: proper NSNumber/String casts.
- [ ] **Track-change detection misses same-title/different-app and identifier-less sources.**
  Parse `bundleIdentifier` + `contentItemIdentifier` and include in `==` (`NowPlayingInfo.swift:19-25`).

## Cluster 3 — agent-activity accuracy (feature currently misleading)

- [ ] **Codex detection is 100% dead.** Session headers are ~22 KB; `firstLine` reads 4 KB → JSON
  parse fails → all 10 real sessions dropped silently (`AgentActivityScanner.swift:189-198`).
  Fix: read chunks until first newline.
- [ ] **Dead sessions reported as "stalled" for up to 2h.** Ground truth right now: pill would say
  "8 agents: 1 working, 2 needs you, 5 stalled" vs 3 actually alive. **Recommended redesign:** use
  `~/.claude/sessions/<pid>.json` (authoritative `pid`/`status: busy|idle|shell`/`cwd`/`kind`,
  maintained by Claude Code 2.1.220) as primary source, JSONL tail as fallback. Validate pid with
  `kill(pid, 0)`. Also fixes label + privacy (no transcript ever opened) + cost.
- [ ] **Dashed project names mangled**: `acme-app` → "tracker", worktree dirs → a ULID
  (`AgentActivityScanner.swift:78-80`). Fixed for free by the sessions-file redesign (`cwd` basename).
- [ ] **Summary republishes every 5s forever** — `AgentActivitySummary` not Equatable, assigned
  unconditionally → pill body re-evaluates every tick even when hidden. Fix: conform Equatable,
  guard before assign (`AgentActivityController.swift:29-31`).
- [ ] **Single giant JSONL entry (seen: 1.36 MB) can exceed the 64 KiB tail** → session silently
  dropped. Fix: escalate tail window (64 KiB → 1 MiB → 4 MiB) when no signal found.
- [ ] **Tail seek can split a UTF-8 char** → decode fails → session dropped. Trim to newline at
  byte level instead of `removeFirst()` (`AgentActivityScanner.swift:205-213`).
- [ ] **Scans can overlap** (no in-flight guard on the 5s timer). Restructure as a single
  `while !Task.isCancelled { scan(); sleep }` loop (`AgentActivityController.swift:18-26`).
- [ ] **Headline overflows the 300pt window** with double-digit counts (measured: current real
  headline clears by 1.3pt). Fixed by the content-driven window sizing in cluster 1.

## Cluster 4 — behavior/UX correctness

- [ ] **Paused music suppresses agent activity forever and pins the dot** — `hasActiveMedia`
  ignores `isPlaying` (`NowPlayingController.swift:34`). Decide: gate on `isPlaying`, or let
  paused media yield the pill. Also revisit priority: suppress agent content only while
  now-playing is *expanded* (a collapsed dot + agent indicator could coexist).
- [ ] **Agent pill is a persistent panel, not a toast** — stays fully expanded for hours; hover
  does nothing in that mode (`setHovering` guards on `hasActiveMedia`). Give it the same
  collapsed/expanded treatment; lift the expand/collapse timer logic into something both modes share.
- [ ] **Artist line near-invisible in Light Mode** — `.secondary` on always-dark capsule
  (`NotchPillView.swift:87`). Fix: `.environment(\.colorScheme, .dark)` on the pill root.
- [ ] **Hover latches the pill open unintentionally** — auto-expand under a stationary cursor sets
  `isHovering` without user intent. Only latch hover from collapsed bounds, or require actual
  mouse movement (`NowPlayingController.swift:79-90`).
- [ ] **All timers stall during menu tracking** — `Timer.scheduledTimer` is `.default` mode only
  (`NowPlayingController.swift:68,86`, `AgentActivityController.swift:18`). Add to `.common`.
- [ ] **Pill follows keyboard focus across displays** — `NSScreen.main` in
  `NotchWindowController.swift:13,54`. Prefer the screen with `safeAreaInsets.top > 0`, else primary.
- [ ] **Display plug/unplug leaves stale notch geometry** — `hasPhysicalNotch` captured once at
  init; reposition never updates the view. Make it observable and update on
  `didChangeScreenParametersNotification`.
- [ ] **On a real notch the collapsed dot renders inside the camera cutout** (invisible) and the
  notch-gap math is dead code (`max(gap, 300)` always 300). Pass the safe-area inset through and
  hang the pill *below* the notch (`NotchGeometry.swift:28-39`, `NotchPillView.swift:54`).
  **Needs verification on a real MacBook.**
- [ ] **Non-notch fallback straddles the menu bar** — sit fully below it:
  `y = maxY - menuBarHeight - height - 6` (`NotchGeometry.swift:39`).
- [ ] **Pill floats over fullscreen video/presentations** with no awareness; consider hiding when
  the menu bar auto-hides (`NotchWindowController.swift:26-27`).
- [ ] **No-display launch fails permanently** — `init?` returns nil, never retried. Retry on
  screen-parameters notification (`NotchWindowController.swift:13`, `AppDelegate.swift:15`).
- [ ] Minor: store/remove the notification observer token; `panel.animator().setFrame` for
  reposition; `panel.animationBehavior = .none`.

## Cluster 5 — animation & polish (the "dynamic island feel")

- [ ] **Morph, don't cross-fade**: collapsed↔expanded runs two overlapping scaled capsules.
  `matchedGeometryEffect` on the artwork + asymmetric transition — biggest single feel upgrade
  (`NotchPillView.swift:26-32`).
- [ ] Play/pause icon: `.contentTransition(.symbolEffect(.replace))` (`NotchPillView.swift:96-98`).
- [ ] Animate content changes within a state: `.animation(value: controller.info)` and on the
  agent headline; `.contentTransition(.numericText())` for the counts (`NotchPillView.swift:41-43`).
- [ ] Button press/hover feedback + pointing-hand cursor (custom ButtonStyle) — important given the
  ~1s command round-trip (`NotchPillView.swift:125-133`).
- [ ] Click targets 20×20 → 24×24 with more spacing.
- [ ] **Reduce Motion**: swap spring/scale for a short fade when
  `accessibilityReduceMotion` (`NotchPillView.swift:21,41-43`); honor Reduce Transparency.
- [ ] **VoiceOver**: labels on transport buttons, combined element for title/artist, hide
  decorative artwork.
- [ ] Shape/material: flat-topped `UnevenRoundedRectangle` + opaque black against a real notch
  (capsule + `.ultraThinMaterial` fine for the floating fallback); add a soft shadow (needs the
  window padding from cluster 1); nicer artwork placeholder (music-note glyph); `.help()` tooltip
  or hover marquee for long titles.
- [ ] Distinguish `.stalled` visually in the agent pill (e.g. orange `exclamationmark.triangle.fill`
  taking precedence); consider "1 agent working" instead of "1 agent: 1 working".
- [ ] Agent pill click action (e.g. focus the owning terminal via pid → parent chain →
  `NSRunningApplication.activate()`; pass an opaque token, keep paths out of the view layer).

## Cluster 6 — packaging, structure, tests

- [ ] **Bundle is un-notarizable**: resource bundle copied to `.app` root (outside `Contents/`) is
  unsealed by codesign. Fix: copy adapter to `Contents/Resources/MediaRemoteAdapter` in
  `build-app.sh` and resolve via `Bundle.main.resourceURL` (keep `Bundle.module` as `swift run`
  fallback). Also removes the crash-on-missing-bundle (`fatalError` in SPM accessor) and the
  embedded `/Users/...` dev path. Update the wrong "fails silently" note in AGENTS.md.
- [ ] **Universal build**: `swift build -c release --arch arm64 --arch x86_64` (output moves to
  `.build/apple/Products/Release/` — update `BIN_PATH`/`RESOURCE_BUNDLE` in `build-app.sh:15-16`).
- [ ] **Sign inside-out, drop `--deep`**, add `--options runtime --timestamp` (`build-app.sh:62`).
- [ ] **Single-instance guard** in `main.swift` (`NSRunningApplication.runningApplications(withBundleIdentifier:)`).
- [ ] **Launch-at-login** via `SMAppService.mainApp` (macOS 13 min already satisfies it).
- [ ] **Split `DesnotchCore` library target**; executable becomes a thin `main.swift` shim — the
  prerequisite for tests. (Only restructure worth doing; feature-folder layout is fine.)
- [ ] **Tests** (priority order): `AgentActivityScanner.classify`; transcript-tail parsing against
  checked-in JSONL fixtures (both formats — these external formats WILL drift); `tailLines`
  boundary behavior; `AgentActivitySummary.headline`; `NowPlayingInfo(adapterPayload:)` graceful
  degradation; `NotchGeometry.placement` (abstract screen inputs); `consume` line-splitting at
  arbitrary chunk boundaries. Parameterize scanner root paths for fixture trees.
- [ ] Hygiene: top-level LICENSE; agent-island attribution in a root NOTICE.md; app icon;
  `.DS_Store` in .gitignore; real bundle id (com.desnotch.app isn't a domain you control);
  version from git tag instead of hardcoded twice; CI (`swift build` + `swift test` on macOS);
  first-run "desnotch is running" feedback.

## Cross-cutting notes

- `CLAUDE.md` references `NotchPillView.contentKind`, which doesn't exist (inline if/else at
  `NotchPillView.swift:25-39`) — extract it or fix the doc.
- Strict-concurrency build currently emits 6 warnings in `MediaRemoteBridge.swift` that become
  errors in Swift 6 mode — cluster 2's serial-queue fix addresses them.
- UI reviewer's measurement probe scripts (rerunnable after fixes) are in the session scratchpad:
  `sizeprobe.swift`, `hitprobe.swift`, `lvl.swift`.
