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
            VoiceWingGlyphHost(model: voice, glyph: glyph, color: voiceWingColor(for: state))
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

/// The left voice wing: the state glyph, plus a small cloud mark whenever this flow's audio or
/// text goes to a cloud service (the agent lane, or the opt-in AI provider for speech or the
/// reply voice). Static, no animation.
@MainActor
struct VoiceWingGlyphHost: View {
    @ObservedObject var model: VoiceSessionModel
    let glyph: VoiceGlyph
    let color: Color

    var body: some View {
        Image(systemName: glyph.rawValue)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .overlay(alignment: .topTrailing) {
                if model.usesCloud {
                    Image(systemName: VoiceGlyph.cloud.rawValue)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(PillPalette.mist.color)
                        .offset(x: 4, y: -2)
                        .accessibilityHidden(true)
                }
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
