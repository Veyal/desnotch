import Foundation

/// What the expanded pill's Talk row shows. Pure, so the gating table is unit-testable without
/// SwiftUI. The row is the on-notch way to start a tap-to-talk capture; it never shows
/// anything derived from a transcript, reply, or command.
enum TalkRowPresentation: Equatable {
    /// Voice is off, nothing would handle the tap (smoke-test mode), or the voice section is
    /// already on screen with its own controls.
    case hidden
    /// Idle and ready: a tap calls `VoiceSessionModel.toggleTalk()`. `shortcut` is the display
    /// string of the configured hot key, or nil while that key is not registered.
    case talk(shortcut: String?)
    /// Microphone or speech access has not been asked for yet: a tap calls
    /// `VoiceSessionModel.requestPermissions()`.
    case allowAccess

    static let talkTitle = "Talk"
    static let allowTitle = "Allow voice access"
    static let talkHint = "Start voice command"
    static let allowHint = "Asks for microphone and speech recognition access"

    static func resolve(
        voiceEnabled: Bool,
        hasHandler: Bool,
        state: VoiceState,
        permissions: VoicePermissionStatus,
        hotkey: VoiceHotkeyChoice,
        hotkeyStatus: PushToTalkStatus
    ) -> TalkRowPresentation {
        guard voiceEnabled, hasHandler, state == .idle else { return .hidden }
        if permissions.microphone == .notDetermined || permissions.speech == .notDetermined {
            return .allowAccess
        }
        return .talk(shortcut: hotkeyStatus == .active ? VoiceSettingsWords.hotkeyLabel(hotkey) : nil)
    }

    var title: String? {
        switch self {
        case .hidden: return nil
        case .talk: return Self.talkTitle
        case .allowAccess: return Self.allowTitle
        }
    }

    var caption: String? {
        if case .talk(let shortcut) = self { return shortcut }
        return nil
    }

    var accessibilityHint: String? {
        switch self {
        case .hidden: return nil
        case .talk: return Self.talkHint
        case .allowAccess: return Self.allowHint
        }
    }

    /// The tap action: asks for access, or starts/ends a tap-to-talk capture (R11/R33).
    @MainActor
    func perform(on model: VoiceSessionModel) {
        switch self {
        case .hidden: break
        case .allowAccess: model.requestPermissions()
        case .talk: model.toggleTalk()
        }
    }

    var glyph: VoiceGlyph { .mic }
    var isVisible: Bool { self != .hidden }
}
