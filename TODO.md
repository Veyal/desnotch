# TODO — current readiness backlog

The historical remediation review is recorded in `CHANGELOG.md`. This file contains only
remaining work that is not already implemented in the current source tree.

## P0 — release confidence

- [x] Confirm the hardened GitHub Actions workflow passes both `swift build` and `swift test` on
  `macos-14`. Local XCTest execution is unavailable with the installed Command Line Tools.
- [ ] Run a packaged-app smoke test on a machine with the required Accessibility/Calendar/media
  permissions and verify clean startup, menu actions, media control, and termination cleanup.

## P1 — hardware and distribution

- [ ] Validate physical-notch placement, collapsed/expanded geometry, screen changes, and menu-bar
  hit testing on a notched MacBook. The current development Mac mini exercises only the fallback.
- [x] Design and validate a universal arm64/x86_64 application build if Intel support is required.
  Host packaging remains the default; `UNIVERSAL=1` builds and verifies both slices.
- [x] Decide whether to add Developer ID signing, notarization, and a production bundle identity
  for external distribution.

## P2 — optional polish

- [x] Add a production app icon and complete external-distribution metadata if the app is shipped
  beyond local development.

## P1 — voice actions and agent control

### Speech to text

- [x] Add `SpeechRecorder` using `AVAudioEngine` with push-to-talk start/stop and cancellation.
- [x] Add `SpeechTranscriptionClient` for OpenAI-compatible `POST /v1/audio/transcriptions`.
- [x] Default model: `gpt-4o-mini-transcribe`; allow configurable base URL and model.
- [x] Store API key in macOS Keychain; never store or log secrets.
- [x] Add microphone permission and clear recording/upload/error states.
- [x] Add Quick Action: “Dictate”. Transcribe recording and paste into focused text input.
- [x] Add Accessibility permission flow for paste into current app.
- [x] Add timeout, retry policy, request cancellation, and audio-size limits.
- [x] Add tests for multipart request construction, response parsing, cancellation, and failures.

### Agent voice control

- [x] Choose agent transport: Claude Code CLI, Codex CLI, or dedicated agent API.
- [x] Define `AgentCommandController` transport and streamed status/output model.
- [x] Add Quick Action: “Talk to Agent”. Transcribe prompt and send it to selected agent.
- [x] Add working-directory and agent selection settings.
- [x] Display transcript, agent state, proposed command, and command output in pill/status menu.
- [x] Require confirmation before command execution.
- [x] Define policy: read-only commands may run automatically; writes, deletes, installs, network,
  `sudo`, credential access, and remote access always require confirmation.
- [x] Add cancellation, command timeout, output truncation, and secret redaction.
- [x] Add audit log without storing API keys or full sensitive transcripts.
- [x] Add tests for command classification, dangerous-command blocking, timeout, cancellation,
  and agent event parsing.

### Integration

- [x] Extend `QuickActionsController` with Dictate and Talk to Agent actions.
- [x] Mirror both actions in status menu for keyboard and VoiceOver access.
- [x] Add settings for provider URL, model, key management, agent backend, and policy.
- [x] Update packaged app `Info.plist` with microphone and Accessibility guidance.
- [x] Run `swift build`, `swift test` in CI, packaged-app static/runtime smoke tests, and the
  non-prompting permission-status probe.
- [ ] Run the permission-granted interactive Dictate/Talk, paste, confirmation, menu-parity, and
  denial/retry flows in a real desktop session.
