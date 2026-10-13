# Changelog

## Unreleased

## v0.12.0 — 2026-10-13

- **Voice control (experimental, off by default):** hold a shortcut to run a closed set of local
  commands (media, volume, a catalogued app, the focus timer) with on-device speech recognition.
  Anything else can go to an optional cloud Hermes agent lane, which is a second opt-in. Microphone
  and Speech Recognition permissions are requested only when voice is enabled.

## v0.11.0 — 2026-10-08

- **Smoother open:** hovering no longer freezes the pill for 30-90 ms while it builds its sections; they
  are built a few per frame (and warmed once shortly after launch), so the shape starts moving at once.
  With Minimal animation or Reduce Motion the shell no longer snaps open to an empty black body before
  the sections appear.
- **Agent detection fixes:** Codex sub-agent sessions (which carry an object-valued source) and headless
  Claude Code runs (`claude -p` and workflow runners) are no longer counted, an interrupted turn (Codex
  or Claude Code) now reads as waiting for you instead of running and then stalled, and a scan that
  briefly loses a session no longer sends a second "Agent needs you". Scanning also skips Claude's
  sub-agent folders entirely.
- **Task titles vanish at once:** turning off "Show agent task titles" clears the titles already on screen
  immediately instead of at the next scan.
- **Steadier wings:** the album-art, note and equalizer indicators keep the same distance from the left
  edge whatever the right wing shows, and the mic/camera dots sit as far from the edge as the other
  right-hand indicators.
- **Lighter idle:** the clipboard poll and the notification-mirror permission recheck pause while the
  display sleeps and slow down in Low Power Mode, and file-tray items pushed out by the 8-item limit
  release their cached thumbnails and icons.
- **Accessibility:** the notch panel now has a VoiceOver name, and the Add Reminder error message uses
  readable text with a red icon.
- **Tray previews respect Privacy mode:** with Privacy mode on, tray rows show a generic document
  glyph instead of the file's Finder/QuickLook thumbnail (a screenshot or document preview is the
  content itself); the filename was already masked.
- **Battery wording follows the power source:** the "On battery" toast, amber rim flash and menu text
  no longer fire while the Mac is still plugged in but not charging (full, or held at about 80% by
  Optimized Battery Charging). The pill row and status menu now read Charging, Plugged in or
  On battery.
- **Calendar access granted later is picked up:** allowing Calendar in System Settings after a denial
  now takes effect as soon as you return to desnotch, with no relaunch.
- **Steadier flashes, stuck-process timing and shutdown:** a short flash can no longer cut a longer
  hold (timer complete, notification) short, the 10-minute stuck-process streak uses the monotonic clock
  so a system clock change cannot flag or hide a process, and a second launch of desnotch no longer
  starts and kills a now-playing adapter process.
- **Mic and camera dots are push-driven:** the indicator now listens for CoreAudio and CoreMediaIO
  "in use" changes instead of probing every 5 seconds, so an idle Mac does no periodic work (the poll
  remains only as a fallback if the listeners cannot be registered).
- **Layout and VoiceOver polish:** list rows (clipboard, tray, processes) share one 24 pt height, the
  agent-count and timer wings keep the same edge spacing as icon wings (the compact pill grows a
  little for them), a lone now-playing title (Privacy mode) centres against the artwork, a
  notification-only stack shows one divider instead of two, calendar and tray VoiceOver labels stay
  current or are no longer duplicated, the collapsed reminder label says "due soon"/"overdue" instead of
  a frozen time, agent rows no longer repeat the project name, and Settings footnotes for features that
  are off stay readable.
- **Every section on a short screen:** with all sections enabled the expanded stack trims its lists
  (clipboard, tray, agents, processes) to fit the display instead of running off it.
- **Countdowns stay current:** "in 12m", due labels, process ages and the notification age refresh
  while the pill is open, the calendar and reminder wing indicators appear and clear on time, and the
  calendar refresh timer stops when Calendar is turned off or the Mac sleeps.
- **Fewer false alarms:** a build that was hot for two minutes before sleep no longer reads as a
  stuck process after waking, turning agent activity off and on no longer swallows the next
  "needs you" notification, and a transcript with a future timestamp is skipped instead of counting
  as active.
- **Hover and sharing fixes:** hover-exit and flash timers apply on the same turn they fire (a stale
  expiry can no longer collapse a newer hover), a display change re-checks the hover state, and the
  tray's Share picker opens next to the pointer instead of at the bottom of the panel.
- **Lighter body passes:** tray rows and the notification banner icon no longer ask LaunchServices for
  icons on the main thread while the pill animates, and the collapsed VoiceOver label no longer reads
  a frozen focus-timer countdown.
- **Settings and onboarding match the new look:** section titles have a quiet glyph and the header
  trait, footnotes are a readable 11 pt, the Animation note describes Subtle/Dynamic/Minimal as they
  now behave, and permission status no longer uses yellow text on a light window. Getting Started
  opens with a miniature of the notch silhouette on a solid background, gained a card about motion
  and Reduce Motion, and its cards get an opaque fill under Reduce Transparency and a stronger edge
  under Increase Contrast.
- **Accessibility polish for the pill:** the focus ring is one shared style (thicker under
  Increase Contrast; it only draws while the pill panel is key, which it deliberately never is, so it
  is not visible today and the status menu stays the keyboard path), highlights and the flash
  spotlight go opaque under Reduce Transparency and stronger under Increase Contrast, the Privacy
  mode row reads as a switch to VoiceOver on macOS 14+, and a row, track line or button that is fading out is hidden from
  VoiceOver immediately instead of being read twice next to its replacement. The expanded content is
  not reachable until it has started to reveal.
- **Internal: no stray animation literals:** press holds, landing highlights, the artwork-glow
  crossfade, the battery sweep and the track-change line delays are now motion tokens (zero or a short
  fade under Reduce Motion), and a source guard test fails on `.onHover` or `repeatForever` in the pill.
- **Fluid pill motion:** the pill now springs open like an extension of the notch - a new
  `NotchShape` silhouette (small concave top ear, bottom corners that grow from 10 to 24 pt on the
  same spring as the frame), content laid out at a fixed width inside the animating clip (no more
  re-wrapping text mid-open), and sections revealing one by one with a light stagger, blur and
  drop-in. Collapse fades content first and settles critically damped, never narrower than the
  hardware. Every duration and curve is now a central token (`PillMotion.swift`); Reduce Motion and
  Minimal still resolve to short fades only (sections fade in over the wings' fade-out in one step), and
  blur is skipped under Reduce Transparency. The expanded shape is never narrower than the minimized
  pill it grows from, even with the timer label or the mic/camera lane showing.
- **Now playing, redone:** the expanded row has larger artwork (40 pt, with a quiet inner edge) that
  pops down slightly and dims when paused, an accent color taken from the album art (progress fill,
  scrub knob, equalizer, and a soft static glow behind the row; plain white in Privacy mode and with
  Reduce Motion/Transparency), and a round play/pause button with a springy press. Changing track
  swaps the title, artist and artwork with a short blur-slide instead of snapping, and titles too long
  for the column now scroll (twice, only while the pill is open) instead of truncating. The seek bar
  grows under your finger, ticks only about once a second instead of 15 times, and gives trackpad
  haptics on begin/commit and at either end. Previous/next nudge in their direction on tap. Titles
  that overflow keep scrolling reliably (a render test fails if the marquee ever freezes), near-black
  artwork gets a visible hairline edge, and the unfilled seek track stays at 3:1 or better on black.
- **Volume readout is visible on notch Macs:** while minimized it now lives in the wings (speaker
  glyph filled to the level on the left, percent on the right) instead of a bar centered behind the
  cutout; the expanded pill shows a floating level chip.
- **Flash-open toasts are classified:** tray drops, power changes, reminders, timers and mirrored
  notifications now hold for a per-kind time, reveal the relevant section first with a brief
  highlight, and tint the rim glow (all finite, no loops). The drop-target rim no longer lightens
  the black shell or changes stroke width.
- **Panel no longer resizes while animating:** the transparent host floor grew to 520x720 (screen
  capped), so spring overshoot and tall stacks do not trigger an AppKit `setFrame`; the rare growth
  is quantized with headroom and applied on the next turn instead of after a frame delay.
- **Sections and wings share one motion language:** agent rows are keyed by session so they move
  instead of rebuilding, with a state chip that crossfades and rings once when an agent needs you;
  the calendar row has a Join capsule that pops once when the meeting becomes imminent; the focus
  timer is a single ring that morphs between running, paused and complete (check draws in) and no
  longer redraws 15 times a second; dropping a file lights the tray well and the new row; new
  clipboard entries and copies flash their row; completing a reminder fills its checkbox and
  strikes the title before it leaves; the battery shows a charge-width glyph with a one-time
  plug-in sweep; the notification row keeps its place when a new banner replaces it; the privacy row
  is a real switch. Rows highlight on press instead of shrinking, and agent, process, tray and
  clipboard lists are capped with a "+N more" line so the stack stays inside the panel. Row titles
  share one text column (icons sit centered in a fixed leading slot), trailing buttons end flush
  with badges and chips, tray rows fit their row, and long clipboard previews end with an ellipsis.
- **Collapsed wings animate hand-overs:** indicators swap with a short scale/fade instead of
  snapping, the timer wing shows a ring with minutes ("24m") or seconds, and a new needs-you agent
  sends two attention ripples then rests as an amber bolt with a badge. Nothing loops, so an idle
  pill still costs nothing; Reduce Motion keeps just the static amber state. Wing glyphs are
  larger (14 pt) and no longer clipped by the notch ear. Mic/camera dots pop in, and show glyphs
  instead of bare dots with Differentiate Without Color. The focus timer's ring with its "25m" label
  and a two-digit agent count grow both wings symmetrically (the cutout gap stays centered), the
  agent count reads "99+" beyond 99, and the mic/camera dots sit in their own lane instead of on top
  of the needs-you badge and the count.
- **Haptics for pill actions:** dropping into the tray, copying a clip, completing a reminder,
  toggling Privacy mode and a finished focus timer give a trackpad tap.
- **Button feel:** pressing a control uses a quick spring and release overshoots slightly.
- **Internal: `AppDelegate` split into focused types:** controller wiring (`AppComposition`), windows
  (`WindowCoordinator`) and the status item/menu (`StatusMenuBuilder`) now live in separate files, and
  the delegate is `@MainActor` so the scattered `MainActor.assumeIsolated` calls are gone. No behavior
  change.
- **Pill controls carry button semantics:** notification, agent, calendar-access and now-playing rows
  are accessibility buttons with labels, the transport buttons are no longer merged into the track
  title, and icon-only buttons have a 24 pt minimum hit target. The pill panel is non-activating and
  never takes keyboard focus, so the status menu remains the keyboard and VoiceOver path to every
  action.
- **Seek bar has adjustable semantics:** it reads "Playback position" with the elapsed and total
  time, and steps 10 seconds per swipe when timeline seeking is enabled and VoiceOver is pointed at
  the pill. Settings sliders now expose
  their label and value.
- **Calendar glance ignores canceled and declined events:** canceled events and events you declined
  no longer show as your next meeting. A slow calendar query can no longer overwrite a newer result
  (or reappear after the glance is turned off).
- **Reminders keep their last good value on a failed fetch:** an EventKit error no longer clears the
  pill's reminder as if the list were empty.
- **Agent notifications no longer carry prompt text:** "needs you" alerts show only the project
  name. Task titles in the pill and status menu are now an opt-in setting ("Show agent task
  titles", off by default); with it off, no prompt text is read from transcripts at all.
- **Separate stuck-process alert toggle:** "Notify when a process looks stuck" is now its own
  setting; it starts with your previous "Notify when an agent needs you" value so nothing
  changes until you adjust it.
- **Agent scanner fixes:** sessions with an unknown working directory are labelled "project"
  instead of a mangled path; a multibyte character at a read boundary no longer drops a Claude
  cwd or Codex header; long runs of non-turn entries at a transcript's end no longer hide a
  session; Codex task titles now resolve; and two sessions in one project no longer share a
  notification identity.
- **Cheaper agent scans:** unchanged transcripts reuse a cached turn state, missing titles are
  not re-read every tick, and the OpenCode query is limited to recent sessions, runs with a
  timeout and output cap, and runs at most every 10 seconds when only the database's WAL changed.
- **Adapter launches are sanitized and back off properly:** every `perl` launch for the now-playing
  adapter (stream, send, seek) ignores inherited `PERL5OPT`/`PERL5LIB`/`DYLD_*`. The relaunch
  backoff now resets only after the adapter produces valid output or runs 10 seconds, so one that
  crashes on startup no longer respawns every second, and leftover bytes from a dead adapter can no
  longer corrupt the first update after a restart. A packaged app with an incomplete bundle (an
  interrupted upgrade, say) now turns now-playing off with a log line instead of crashing at launch.
- **No more idle polling:** the mic/camera indicator, agent scan, and stuck-process monitor start and
  stop with their Settings toggles and pause while the display or system sleeps or the session is
  inactive; Low Power Mode triples their intervals. Reminders follow the same rule: its 30-second tick
  only re-reads the clock, and EventKit is queried on changes, on wake, when a reminder becomes
  overdue or urgent, and every ten minutes as a safety net (overdue reminders are looked up a year
  back instead of ten).
- **Lighter stuck-process monitor:** flagged processes are re-checked with a pid-scoped `ps` instead
  of a full process listing every 5 seconds, and a failed or timed-out sample is skipped instead of
  wiping the monitor's state.
- **Bounded agent-host lookup:** the click-to-focus helpers (`lsof`, `ps`) now run through the shared
  subprocess runner with a timeout, an output cap, and cancellation by a newer click.
- **Settings export, import, and reset:** Settings has a "Settings file" row to export your
  preferences to JSON, import them back, or reset everything to defaults. The file holds only
  switches, sizes, and style choices, so it never includes muted app names, event or reminder
  text, agent titles, or clipboard content. Imports accept only known settings with the right
  type, clamp numbers to their ranges, and refuse oversized or newer-version files.
- **Launch at login in Settings:** the same toggle as the status menu, now also in Settings. If
  macOS needs you to approve it, the app says so and links to Login Items instead of silently
  staying off.
- **Check for updates setting:** the daily GitHub release check can be turned off in Settings
  (on by default); when off, desnotch makes no network request. Turning it back on checks
  immediately.
- **Settings groundwork:** stored settings now carry a schema version with a migration step
  (existing values are unchanged), and a new "pill display" preference (automatic by default)
  is stored for choosing which screen hosts the pill.
- **Keyboard and VoiceOver access to the notch:** the status menu has a "Show Notch" item that
  holds the pill open until you choose it again, and an optional global shortcut (Option-Command-N,
  off by default, Settings > Behavior) does the same without any extra permission. If another app
  already owns the shortcut, Settings says so. Getting Started mentions both.
- **Status menu mirrors more glances:** high-CPU processes and battery level now appear in the
  status menu alongside the next meeting, reminders, and agents.
- **Choose which display hosts the notch:** Settings > Notch panel has a Display picker (Automatic by
  default). Automatic prefers a display with a notch, then the primary display, and no longer jumps
  to whichever monitor has keyboard focus. A saved display that is unplugged falls back to Automatic,
  and the pill moves immediately when you change the choice or attach/detach a monitor.
- **Copy Display Diagnostics:** a status menu item copies every display's frame, safe-area inset,
  notch areas, and where the pill sits, for bug reports about notch fit.
- **VoiceOver announcements for pill events:** tray drops, reminder changes, timer start/finish,
  plugging or unplugging power, and volume scroll (read once, after you stop scrolling) are now
  announced. Notification banner text is never announced.
- **Tag-driven releases:** pushing a `v*` tag builds a universal, hardened-runtime app, checks the
  tag against `CHANGELOG.md` and the bundle's `Info.plist`, runs the smoke tests, and publishes
  `desnotch-v<version>-universal.zip` with a SHA-256 file and the changelog section as notes
  (`RELEASING.md`).
- **Stricter packaging:** `scripts/build-app.sh` signs every nested Mach-O inside-out with a secure
  timestamp for real identities, verifies the result with `codesign --verify --deep --strict`,
  and can notarize with a keychain profile or App Store Connect API key (checks for `Accepted`,
  staples, then validates with `stapler` and `spctl`). The hardened-runtime build is signed with the
  calendars entitlement (`scripts/desnotch.entitlements`; EventKit needs it for both the Calendar
  glance and Reminders) and the build and smoke test fail if it is missing. It no longer falls back to version 0.1.0
  when there is no tag: set `VERSION` or fetch tags.
- **Pinned vendored adapter and bundled licenses:** `VENDOR.sha256` pins the MediaRemote adapter and
  is verified on every build; the app bundle now includes `LICENSE`, `NOTICE.md`, and the adapter's
  BSD-3-Clause license in `Contents/Resources`.
- **Broader CI:** tests and packaging run on macOS 14 and 15, a universal hardened-runtime job
  runs the packaged smoke tests, and ShellCheck and a minimal SwiftLint run on every change.
  The runtime smoke test now polls with deadlines and leaves no temp logs behind.
- **Docs:** README discloses the daily GitHub update check (and its Settings switch) and exactly what
  the agent scan reads; vendor notices point at the current source paths; new `CONTRIBUTING.md`.
- **More test coverage for risky logic:** panel placement (notch vs fake notch, offset displays),
  the pill's hit-test rect, the adapter stream's line framing and relaunch backoff ladder, and
  settings migrations are now unit-tested through small pure seams. Fixed-duration sleeps in the
  notification-mirror and polling tests were replaced with deterministic main-queue draining.
- **Internal: scanner and pill split into per-provider and per-section files:**
  `AgentActivityScanner` now orchestrates one `AgentSessionSource` per provider (Claude Code, Codex,
  Pi, OpenCode) with shared cache and transcript-reading helpers in their own file, and
  `NotchPillView` is split into `NotchPillView+<Section>.swift` extensions. Behavior is unchanged.

## v0.10.0 — 2026-09-01

- **Session-scoped focus timer:** start a 5, 15, 25, or 50 minute session from the
  status menu, then pause, resume, cancel, or dismiss it from the menu or notch. The
  absolute wall-clock deadline survives sleep/wake without drift, completion provides
  sound and VoiceOver feedback, and no timer state is persisted.
- **Purposeful notch motion:** expansion now stages the container before its content and
  reverses that hand-off on collapse, while rapid hover reversals retarget cleanly. Section
  layout, content replacement, direct controls, and transient feedback use separate motion
  channels; Reduce Motion removes geometric effects, and the panel keeps a stable host size.
- **Expanded tray actions:** tray items can be opened, revealed in Finder, copied, shared,
  or removed from both row context menus and the status menu without moving or deleting the
  underlying files.
- **Cheaper agent scans:** immutable Pi session facts and unchanged OpenCode query results
  are cached with bounded, lock-protected invalidation so the five-second activity scan does
  not repeatedly parse the same files or query an unchanged database.

## v0.9.0 — 2026-08-31

- **Homebrew distribution restored:** the dedicated `Veyal/desnotch` cask tracks v0.9.0 and
  supports `brew upgrade --cask desnotch`. The release remains ad-hoc signed and not notarized;
  first launch uses Finder's **Open** action or **Open Anyway** in System Settings, without
  stripping macOS quarantine metadata.
- **Actionable reminders:** optional and off by default; shows the next overdue/nearby due
  reminder using public EventKit APIs, supports completion and privacy-safe quick capture from
  both pill and status menu, and keeps no reminder database of its own.
- **Getting Started guide:** a one-time, privacy-safe window teaches the otherwise hidden hover,
  scroll-volume, file-drop, optional-feature, and Privacy Mode interactions. It stays reopenable
  from Settings and the status menu.
- **Recovered CPU warnings clear promptly:** process utilization now comes from interval CPU time
  rather than `ps`'s decaying average, while preserving the 10-minute sustained threshold and
  keeping fast sampling limited to the period when a warning is already visible.
- **Focused utility surface:** removed the experimental voice dictation and AI command controls,
  including their microphone, provider-key, and Codex transport settings. Privacy Mode is now the
  pill's single utility action; the occasional Keep Display Awake control remains in the status
  menu and still owns only its own session-scoped `caffeinate` process.
- **Private clipboard pocket:** optional and off by default; keeps up to eight bounded plain-text
  copies in memory only, ignores password-manager/transient pasteboard markers, deduplicates, and
  clears on disable or quit. Copy/remove/clear actions are available in the pill and status menu,
  with Privacy Mode redaction.
- **One-click meeting join:** recognized HTTP(S) conferencing links from calendar event URL,
  location, or notes are available from both the calendar row and status menu. Notes and locations
  are inspected transiently and never rendered or persisted.
- **Smoother pill layout:** natural size now travels through one combined SwiftUI preference,
  avoiding duplicate panel-resize/interactivity work during every animated layout pass. Competing
  root animation modifiers are consolidated into primary/secondary state transactions,
  and calendar time formatting no longer constructs a formatter per render.
- **Now-playing and notification reliability:** reconciliation distinguishes adapter failure from
  a valid empty result, generation-checks one-shot results so stale work cannot overwrite newer
  stream state, and notification menu actions stay bound to the banner they rendered.
- **Distribution readiness:** refreshed production app icon, host/static and runtime bundle smoke
  checks, optional validated universal arm64+x86_64 builds, configurable bundle identity, and
  opt-in Developer ID/hardened-runtime/notarization support. The non-prompting packaged-app probe
  reports Accessibility, Calendar, and Reminders authorization state. External signing and physical-notch/
  Intel runtime checks remain gated on the corresponding credentials and hardware.
- **Privacy fixes:** agent task titles, media metadata, calendar/reminder titles, clipboard previews,
  and tray filenames no
  longer leak through VoiceOver labels or tooltips while Privacy mode is enabled.

## v0.8.1 — 2026-08-01

- ✓ **Fix: Settings window couldn't reach its lower half.** The window was sized to the
  full height of its content, which had outgrown the screen, and it had no scrolling and
  no resize control — so the bottom rows (including the notification permission flow)
  were unreachable. The pane now scrolls, and the window opens at a height that fits the
  screen and can be resized vertically. Same width, controls, and layout as before.

## v0.8.0 — 2026-08-01

- ✓ **Animation style** (Settings › Animation: Subtle / Dynamic / Minimal, default
  Subtle): one motion vocabulary for the whole pill — a restrained spring on real
  events, short fades for everything else. Minimal removes motion entirely, and
  macOS Reduce Motion always wins regardless of the setting. Press feedback, the
  play/pause symbol swap, the scrub knob, tray rows, and the needs-you/notification
  pulses all follow it; several of those previously animated even under Reduce Motion.
- ✓ **Nothing loops by default**: the minimized music indicator now defaults to the
  static note. The equalizer animates continuously while music plays, so it is opt-in
  from Settings › Music indicator (an explicit existing choice is preserved).
- ✓ **Clicking an agent row opens the terminal actually running it** instead of
  whichever terminal happened to be first in a fixed list. The owning app is resolved
  from the agent process's working directory and its process ancestry, with the old
  behavior as fallback (agents inside tmux/cmux still fall back). The lookup is
  time-bounded and the newest click wins.
- ✓ **Fix: album art stuck on the previous song.** The artwork cache keyed on data
  that didn't identify the image — for JPEG artwork every track produced the same key,
  so the first track's cover was reused forever, and a track id could be permanently
  bound to stale artwork. The key is now a SHA-256 of the artwork bytes. Affected both
  next and previous, and the expanded row as well as the new Album art indicator.

## v0.7.0 — 2026-07-31

- ✓ **Hide the macOS banner after mirroring** (Settings, off by default): when a
  notification is mirrored into the notch, desnotch closes the system banner so the
  notch is the only place it shows. macOS has no supported way to stop a banner from
  appearing — and Do Not Disturb would hide it from the notch too — so it is closed
  right after it appears; expect a brief flash. Only banners desnotch actually
  mirrored are closed (muted apps keep their normal banner), and the notification
  itself is untouched in Notification Center.

## v0.6.1 — 2026-07-31

- ✓ **Fix: notification rows titled "Notification Center"**: the banner reader was
  picking up Notification Center's own window title (and its action buttons) as
  notification text, and the running-app matcher then claimed it as the sending app.
  Scaffolding chunks are now filtered before app identification, so rows show the
  real sender (Telegram, WhatsApp, …).
- ✓ **Notification row restyle**: compact alert anchored on the source — larger app
  icon (with a matching tile behind the bell fallback), app name as the primary
  line, content secondary. Click-to-open, mute, privacy mode, accessibility, and
  reduced motion unchanged.

## v0.6.0 — 2026-07-31

- ✓ **Music indicator styles** (Settings › Music indicator): choose what the minimized
  wing shows for media — Equalizer (animated bars while playing, the default), Note
  (always static), or Album art (the current track's artwork, dimmed while paused).
  Album art falls back to the equalizer/note when a track has none, and Privacy mode
  suppresses it (artwork identifies the track on a screen-shared surface). Reduce
  Motion never gets the animated bars.
- ✓ **Smarter notification source matching**: the mirrored-banner parser now scans all
  banner text chunks for a running app's name instead of trusting the first chunk, so
  sender-first banner layouts still resolve the real app (Telegram, WhatsApp, …).
  Browser-delivered web notifications (e.g. WhatsApp Web in Chrome/Safari) stay
  attributed to the browser — first match in banner order wins. Adds content-free
  diagnostic logging (counts/booleans only, never notification text).

## v0.5.0 — 2026-07-31

- ✓ **Notifications in the notch** (new, off by default): mirrors notification banners
  as an animated top row in the pill — app icon, app name, one truncated line — with
  a bell in the compact wing that pulses per arrival. Click jumps to the source app;
  per-app mute from the status menu. Uses only the Accessibility permission (no Full
  Disk Access, no private APIs); Settings walks you through granting it, and the
  feature activates automatically once granted. Nothing is stored: banners live in
  memory for 60 seconds, content is capped at 64 characters, and Privacy mode reduces
  the row to "App — Notification".
- ✓ **Animated now-playing indicator**: the minimized music note becomes a tiny
  three-bar equalizer that dances while media is actually playing and settles back to
  the note when paused. Zero cost at rest; Reduce Motion keeps the static note.

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
  appears in the status menu and opens the latest GitHub release.
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
