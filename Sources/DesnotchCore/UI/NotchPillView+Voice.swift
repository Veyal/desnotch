import SwiftUI

extension NotchPillView {
    var hasVoice: Bool { voiceState != .idle }

    var voiceSection: some View {
        VoiceSectionHost(
            model: voice,
            privacyMode: settings.privacyModeEnabled,
            width: expandedContentWidth,
            motion: motion,
            contrast: contrast,
            reduceTransparency: reduceTransparency
        )
    }

    static func voiceCompactLabel(_ state: VoiceState?) -> String? {
        guard let state, let word = VoiceStateWords.wingWord(for: state) else { return nil }
        return "Voice: \(word)"
    }

    @ViewBuilder
    func voiceWingGlyph(for state: VoiceState) -> some View {
        if let glyph = VoiceGlyph.wing(for: state) {
            Image(systemName: glyph.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(voiceWingColor(for: state))
                .frame(width: 16, height: 16)
        } else {
            EmptyView()
        }
    }

    func voiceWingColor(for state: VoiceState) -> Color {
        switch state {
        case .awaitingApproval, .error: return PillPalette.amber.color
        case .paused: return PillPalette.red.color
        case .armed, .transcribing: return PillPalette.mist.color
        default: return .white
        }
    }
}

@MainActor
struct VoiceWingMeterHost: View {
    @ObservedObject var model: VoiceSessionModel
    let motion: NotchAnimation.Motion

    init(model: VoiceSessionModel, motion: NotchAnimation.Motion) {
        self.model = model
        self.motion = motion
    }

    var body: some View {
        VoiceMeter(levels: model.levels, motion: motion)
    }
}

@MainActor
struct VoiceAnnouncementModifier: ViewModifier {
    let state: VoiceState
    let model: VoiceSessionModel

    func body(content: Content) -> some View {
        content.onChange(of: state) { newState in
            guard let announcement = VoiceAnnouncementPolicy.announcement(
                for: newState, severity: model.errorSeverity
            ) else { return }
            AccessibilityAnnouncer.announce(
                announcement.message,
                priority: announcement.isHighPriority ? .high : .medium
            )
        }
    }
}
