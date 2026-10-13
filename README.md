# desnotch

Lightweight native macOS notch app for media, local coding-agent activity, and other ambient
system status.

desnotch keeps a compact pill visible at the top of the screen and expands it on hover. It can
show system-wide now-playing artwork and transport controls, local Claude Code/Codex/Pi/OpenCode
activity, calendar glance, process and media-use status, battery changes, notification banners,
and a file tray. A session-scoped focus timer provides 5/15/25/50-minute live countdowns without
an account, permission, or background polling. An opt-in clipboard pocket keeps up to eight recent
plain-text copies in memory only, recognized Zoom/Teams/Meet/Webex-style calendar links open with
one click, and an opt-in Reminders row surfaces the next due task with complete and quick-capture
actions. Tray files can be opened, revealed in Finder, copied, shared, or removed without moving
the originals.

The status-bar menu provides the keyboard and VoiceOver path for media transport, focus timers,
agent actions, meeting links, reminders, tray and clipboard items, notification actions, privacy
mode, display-awake mode, the reopenable Getting Started guide, settings, launch at login, and quit.
See `AGENTS.md` for load-bearing privacy, geometry, and runtime invariants.

## Install and upgrade with Homebrew

Requires macOS 13 Ventura or later. The fully qualified install command adds the dedicated tap
and installs `desnotch.app` into `/Applications`:

```sh
brew install --cask Veyal/desnotch/desnotch
```

Future releases use the normal short cask name:

```sh
brew upgrade --cask desnotch
```

The current release is ad-hoc signed and not notarized. If macOS blocks the first launch,
right-click `desnotch.app` and choose **Open**, or use **Open Anyway** in
**System Settings → Privacy & Security**. Developer ID signing and notarization remain the
distribution-quality follow-up.

## Running in development

Requires Xcode's command line tools (for `swift`) - no Xcode GUI project needed.

```sh
swift run
```

`swift build` also works standalone. `swift test` requires an XCTest-capable Xcode toolchain;
the GitHub Actions macOS runner is the authoritative test environment for this machine, whose
Command Line Tools installation does not include XCTest.

The app has no dock icon (`LSUIElement`/accessory activation policy). A menu bar status item
provides a reliable Quit and a Launch-at-Login toggle (the notch panel itself can't become the
key window, so the app menu's Cmd+Q isn't always reachable). `pkill desnotch` is also safe -
SIGTERM/SIGINT are handled and clean up the perl adapter subprocess instead of orphaning it.

## Building the distributable `.app`

```sh
scripts/build-app.sh
```

This runs `swift build -c release`, bundles the host-architecture binary into `dist/desnotch.app`
with a minimal `Info.plist`, places the MediaRemote adapter under
`Contents/Resources/MediaRemoteAdapter`, and copies `LICENSE`, `NOTICE.md`, and the adapter's
BSD-3-Clause license into `Contents/Resources`. Before assembling it checks the vendored adapter
against `VENDOR.sha256` and validates version/build metadata and required resources. It then
codesigns inside-out (every nested Mach-O, then the framework, the executable, and the app; no
`--deep` signing) and finishes with `codesign --verify --deep --strict`.

The version comes from `VERSION=x.y.z` or, failing that, the latest git tag. There is no silent
fallback: a checkout with neither (for example a shallow clone without tags) stops with an error.
The current host build remains the default. For a validated arm64+x86_64 executable, opt in with
`UNIVERSAL=1 scripts/build-app.sh`; it cross-builds both targets and lipo-merges them (the adapter
is already universal). A stable reverse-DNS bundle ID can be selected with
`BUNDLE_ID=com.example.desnotch`. For external distribution, provide a Developer ID identity and
hardened runtime explicitly (real identities also get a secure `--timestamp`):

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
HARDENED_RUNTIME=1 scripts/build-app.sh
```

Notarization is also opt-in. Credentials are never stored in the repository: use either a
preconfigured notarytool keychain profile or an App Store Connect API key supplied through
environment variables. The script submits, waits, requires an `Accepted` result, staples the
ticket, and runs `stapler validate` and a Gatekeeper `spctl` assessment:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" HARDENED_RUNTIME=1 \
NOTARIZE=1 NOTARY_PROFILE=desnotch-notary scripts/build-app.sh

# or, with an API key (NOTARY_ISSUER_ID is needed for team keys):
NOTARIZE=1 NOTARY_KEY_PATH=~/keys/AuthKey_ABC123.p8 NOTARY_KEY_ID=ABC123 \
NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" HARDENED_RUNTIME=1 \
scripts/build-app.sh
```

Developer ID signing and notarization are pending the owner's credentials. Until then, Gatekeeper
may warn on other machines; use the first-launch confirmation above. Drag `dist/desnotch.app` to
`/Applications`, or run it directly with `open dist/desnotch.app`. Maintainers: see
[`RELEASING.md`](RELEASING.md) for the tag-driven release workflow.

## How it works

- **Now-playing data & control**: via the private `MediaRemote.framework`, since there is no
  public API for system-wide now-playing state. As of macOS 15.4, Apple entitlement-gated the
  relevant call, so the app uses the vendored adapter subprocess described in
  `Sources/DesnotchCore/MediaRemote/Vendor/MediaRemoteAdapter/NOTICE.md`. Packaged apps resolve
  it from `Contents/Resources/MediaRemoteAdapter`; `swift run` uses the SwiftPM resource.
  Updates stay notification/stream-driven, never polled, so idle CPU stays near zero.
- **Agent activity**: on by default; turn it off in Settings > "AI agent activity". It reads
  only local session-log locations for Claude Code, Codex, Pi, and OpenCode
  (`~/.claude/projects`, `~/.codex/sessions`, `~/.pi/agent/sessions`, and OpenCode's local
  SQLite database, read-only) to decide whether each session is working, waiting for you, or
  stalled. Nothing leaves the machine. The pill and status
  menu show only counts and a project folder name; prompt text is never read unless you turn on
  "Show agent task titles" (off by default, 48 characters at most), and notifications never
  include it.
- **Update check**: on by default. Once a day desnotch asks GitHub's public releases API
  (`api.github.com/repos/Veyal/desnotch/releases/latest`) whether a newer version exists and
  shows a status-menu item if so. The request carries no identifiers beyond a fixed
  `User-Agent`. Turn it off with Settings > "Check for updates" (`checkForUpdates`); when off,
  desnotch makes no network request of its own. That stays true only while the optional Hermes
  voice lane is also off: with the lane on, the Hermes child is the other network path.
  Development builds without a bundle version never check.
- **Notification mirror**: optional and off by default. It uses an Accessibility observer for
  notification banners, keeps banner content in memory only, and does not scrape the notification
  database.
- **Clipboard pocket**: optional and off by default. It polls only the pasteboard change counter,
  stores at most eight bounded plain-text items in memory, skips concealed/transient password-
  manager copies, clears immediately when disabled or when the app exits, and redacts previews
  while Privacy Mode is enabled.
- **Calendar join**: EventKit supplies the next event. Only recognized HTTP(S) conferencing hosts
  become a Join action; event notes and locations are inspected transiently and never displayed or
  persisted.
- **Actionable reminders**: optional and off by default. EventKit supplies the next incomplete due
  reminder (overdue first, otherwise nearest within seven days). Titles are bounded, Privacy Mode
  redacts them, and create/complete actions write directly to the user's default Reminders list;
  desnotch keeps no reminder database.
- **Focus timer**: one session-scoped countdown driven by an absolute deadline, so sleep/wake and
  UI workload do not introduce drift. It schedules one completion event and only redraws progress
  while the timer is visible; there is no repeating controller poll and nothing is persisted.
- **Motion system**: the notch container, section arrivals, content replacements, direct controls,
  and one-shot feedback use separate motion channels. Expansion is an interruptible shape-to-content
  hand-off, Reduce Motion makes geometry changes immediate, and the opt-in equalizer remains the only
  perpetual animation.
- **Getting Started**: a one-time, privacy-safe guide explains hover, volume scroll, file drops,
  optional utilities, and Privacy Mode. It can always be reopened from Settings or the status menu.
- **Notch geometry**: on a MacBook with a physical notch, the pill is sized and positioned
  using `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` to hug
  the actual notch cutout. On a screen with no notch (this project was developed on a
  Mac mini, which has none), it renders the same wings-around-cutout layout around a synthetic
  MacBook-sized notch at the top center of the screen.

See `AGENTS.md` for implementation details load-bearing for anyone continuing this project, and
[`CONTRIBUTING.md`](CONTRIBUTING.md) for build, test, and lint instructions.

## Voice control

Off by default. In Settings, turn on "Voice control", then hold the shortcut and speak. The
default shortcut is Option-Command-V. While Finder is frontmost that chord is also Finder's
"Move Item Here". Settings offers two other choices, Shift-Option-Command-V and
Option-Command-J, which avoid it. A short review window runs before anything happens, and you
can cancel it. You can also click the Talk row in the expanded notch, which starts a listening
session without the shortcut; click Done to send it.

Local commands have to match the whole utterance. They cover play, pause, next, and previous;
volume up, down, mute, unmute, or a percent (above 70% asks for a click); opening a catalogued
app (Safari, Chrome, Terminal, iTerm, Finder, Notes, Calendar, Reminders, Music, Spotify,
Messages, Mail, System Settings, Activity Monitor, Calculator, Preview, Visual Studio Code, or
Notion); and starting or cancelling a timer of 1 to 120 minutes. English and Indonesian phrases
are both accepted. The recognition locales are English (US) and Bahasa Indonesia; Indonesian
needs the on-device dictation asset, and a locale without on-device recognition fails closed.

Audio stays in memory and is never saved. By default recognition stays on this Mac.
Transcripts, replies, and commands are not logged, not announced to VoiceOver, and not put in
the status menu. They clear when the session returns to idle.

### AI provider (optional)

Settings > Voice control > AI provider chooses, step by step, what stays on this Mac:

| Step | Default | Opt-in |
|---|---|---|
| Speech-to-text | On this Mac | OpenAI-compatible (`POST {base}/audio/transcriptions`) |
| Answers (anything that is not a built-in command) | Off | Hermes agent, OpenAI-compatible (`{base}/chat/completions`), or Claude (`{base}/v1/messages`) |
| Spoken replies (with "Speak replies" on) | macOS voice | OpenAI-compatible (`{base}/audio/speech`) |

"OpenAI-compatible" means any service with the OpenAI API shape: OpenAI
(`https://api.openai.com/v1`, the default), Groq, OpenRouter, or a server on this Mac such as LM
Studio, Ollama, or a whisper server. Claude answers questions only; Anthropic has no speech API,
so speech and spoken replies stay on this Mac or use the OpenAI-compatible provider. Leave the
language hint empty to auto-detect, which suits mixed Indonesian and English.

When you choose a provider for a step:

- That step's audio (speech-to-text) or text (answers, spoken replies) goes only to the base URL
  you entered, and only when the step runs. Audio is captured into memory, encoded as a WAV in
  memory, and uploaded only after you end the capture (release the key or press Done; a capture
  the 30-second cap ends is discarded). There are no partial transcripts; the notch shows
  "Transcribing…".
- A cloud mark shows on the voice wing and in the voice card while that happens.
- Base URLs must use https. Plain http is accepted only for `localhost`, `127.0.0.1`, or `::1`.
  Redirects are refused.
- API keys are saved only in your Keychain (`com.desnotch.app.voice-ai`, and
  `com.desnotch.app.voice-ai.anthropic` for Claude). They are never shown, logged, exported, or
  written to the audit log. A server on this Mac may run without a key.
- A saved key is bound to the host and port it was saved for. After you change the base URL to
  another host, Settings shows "Key saved for <host> — re-enter for this host" and nothing is
  sent with that key. URL and model fields apply when you press Return or leave the field.
- desnotch saves no audio, transcript, or reply. The provider's own retention policy applies.
- Provider settings, including the base URLs, are never exported or imported.
- Answers keep every agent-lane rule: the 1.5-second review window, the daily limit, Stop, and the
  rule that nothing goes to the cloud unless you ended the capture. Answers are short and spoken
  style, and use no tools unless you turn on machine control (below). If the spoken-reply request
  fails, the macOS voice reads the reply.

### Let the agent control this Mac (optional)

With the OpenAI-compatible or Claude answers, a second switch, "Let the agent control this Mac"
(off by default), lets the model use desnotch's own tools. desnotch runs each tool itself and
checks it before it starts:

| Runs on its own | Waits for you to hold Approve on the card | Always refused |
|---|---|---|
| open an app, open a plain web link, play/pause/next/previous, volume up to 70%, the focus timer, system info (time, battery, disk, frontmost app, now playing), list/read/search files in your home folder (not hidden folders or `~/Library`), fetch a plain public web page | run a shell command, an AppleScript or a Shortcut, write a file in your home folder (the card must show all of it), read or write the clipboard, volume above 70%, a link or page whose address has a query, read a file outside the quiet scope | network commands (`curl`, `ssh`, `git push`...), `sudo`, piping into an interpreter, command substitution, anything touching `.ssh`, `.hermes`, keychains, credentials or engagement/evidence/pentest folders, writes outside your home folder's ordinary folders, local-network or tailnet addresses, unknown tools |

The card shows the exact command, path or link (hidden while Privacy mode is on, and then it
cannot be approved). Saying "yes" never approves. Commands run in
`~/Library/Application Support/desnotch/agent-scratch` with a clean environment, a 30-second limit
and capped output, and Stop kills them. What a tool returns (file contents, web pages, command
output) is sent to your AI provider and treated as data, never as instructions. The audit log
records only which tool ran, its tier and outcome. The first AppleScript that controls an app makes
macOS ask for Automation permission. Computer use (screenshots, clicks) is not included.

The Hermes agent is one of the "Answers" choices. The agent
lane needs a locked Hermes profile. You create it; desnotch only reads it. The file is
`~/.hermes/profiles/voice/config.yaml`. After writing it, lock that file with `chflags uchg`.
A profile that passes the preflight looks like this:

```yaml
approvals:
  mode: manual
command_allowlist: []
mcp_servers: {}
platform_toolsets:
  acp: []
```

With that empty toolset, an agent tool call usually ends in a tripwire pause. That pause is the
expected outcome: the tool is not allowlisted, so the lane stops instead of running it.

## Current Boundaries

- **Real notch geometry is untested on this dev machine.** This project was developed on a
  Mac mini, which has no physical notch, so notch-hugging geometry only ever exercised the
  fallback path here. Final animation/geometry polish against a *real* notch cutout should
  happen on an actual notched MacBook.
- Notification mirroring is Accessibility- and macOS-version-dependent.
- Distribution signing and notarization require the explicit opt-in configuration described above.
- Accessibility has no standard Info.plist usage-description key. Enable it for notification
  mirroring in System Settings → Privacy & Security → Accessibility; the app documents and
  rechecks that grant. Calendar and Reminders use their standard usage-description keys, and
  Reminders access is requested only after its off-by-default feature is enabled. Microphone
  and Speech Recognition use their standard usage-description keys and are requested only
  after voice control, which is off by default, is enabled.
- Universal builds and external signing/notarization are explicit opt-ins. The default host build
  is intentionally retained, and real-notch/Intel runtime verification remains hardware-gated.

## Packaging smoke checks

CI runs `scripts/smoke-test.sh` after packaging. Locally, use `scripts/smoke-test.sh` to validate
plist keys, icon and adapter resources, executable architecture, strict nested signatures, and
obvious orphaned adapter processes. `scripts/runtime-smoke-test.sh` launches the packaged binary
in non-interactive smoke mode, verifies the adapter starts, sends SIGTERM, and proves both owned
processes exit. `scripts/permission-status.sh` prints a non-prompting Accessibility, Calendar, and
Reminders authorization snapshot. Because macOS may attribute a shell-launched Accessibility check to the
responsible parent process, treat `trusted` as diagnostic and verify the normally launched app
before relying on `REQUIRE_GRANTED=1`; set `REQUIRE_REMINDERS_GRANTED=1` only when validating the
opt-in Reminders feature. The script documents this caveat beside the check.
`MANUAL=1 scripts/smoke-test.sh` prints the interactive permission/media/menu/termination/notch/
Intel checklist; those checks require a desktop session and appropriate hardware.
