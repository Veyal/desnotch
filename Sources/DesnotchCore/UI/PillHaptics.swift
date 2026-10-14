import AppKit

/// Trackpad haptics for direct, user-initiated pill actions. Driven only from button
/// actions and gesture callbacks - never from hover, expansion, polling or any change the
/// user did not make. The one observer-driven event is `timerComplete`: a timer the user
/// started finishing. The system manager is a silent no-op without a
/// force-touch trackpad and follows the user's system trackpad setting, so there is no
/// setting of our own.
enum PillHaptics {
    enum Event: CaseIterable {
        /// Previous / play-pause / next tapped.
        case transport
        /// A seek-bar drag (or click) began.
        case scrubBegin
        /// The seek was committed (pointer released).
        case scrubCommit
        /// The scrub reached the start or end of the track.
        case scrubEdge
        /// A file was accepted into the tray.
        case trayDrop
        /// A clipboard entry was copied.
        case clipboardCopy
        /// A reminder was completed (not on failure).
        case reminderComplete
        /// A focus timer the user started ran out.
        case timerComplete
        /// The privacy switch was toggled.
        case privacyToggle
        /// Voice capture became live (the first audio buffer, not the key-down).
        case voiceStart
        /// A voice command was committed, or a reply finished.
        case voiceCommit
        /// An approval card appeared.
        case voiceNeedsConfirm
        /// The user approved a card.
        case voiceApproved
        /// The Talk row was tapped.
        case voiceTalkTap
        /// A voice failure. Two taps, same as a finished timer.
        case voiceError
    }

    /// Haptics closer together than this are dropped, so a begin immediately followed by a
    /// commit (a plain click on the bar) is one tap, not a buzz.
    static let minimumInterval: TimeInterval = 0.08

    static func pattern(for event: Event) -> NSHapticFeedbackManager.FeedbackPattern {
        switch event {
        case .transport, .clipboardCopy, .privacyToggle, .voiceCommit, .voiceTalkTap: return .generic
        case .scrubBegin, .scrubCommit, .trayDrop, .voiceStart: return .alignment
        case .scrubEdge, .reminderComplete, .timerComplete, .voiceNeedsConfirm, .voiceApproved, .voiceError:
            return .levelChange
        }
    }

    /// Taps in one haptic event (a completed timer, and a voice failure, are a double tap).
    static func tapCount(for event: Event) -> Int {
        switch event {
        case .timerComplete, .voiceError: return 2
        default: return 1
        }
    }

    /// Gap between the taps of a multi-tap event, comfortably above `minimumInterval`.
    static let repeatInterval: TimeInterval = 0.12

    /// Pure rate-limit decision (monotonic seconds).
    static func shouldPlay(now: TimeInterval, lastPlayed: TimeInterval?) -> Bool {
        guard let lastPlayed else { return true }
        return now - lastPlayed >= minimumInterval
    }

    @MainActor private static var lastPlayed: TimeInterval?

    @MainActor
    static func play(_ event: Event) {
        let now = ProcessInfo.processInfo.systemUptime
        guard shouldPlay(now: now, lastPlayed: lastPlayed) else { return }
        lastPlayed = now
        let pattern = pattern(for: event)
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        for tap in 1..<max(1, tapCount(for: event)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + repeatInterval * Double(tap)) {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            }
        }
    }
}
