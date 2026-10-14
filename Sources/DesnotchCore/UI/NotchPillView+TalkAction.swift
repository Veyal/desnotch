import SwiftUI

/// The expanded pill's Talk row: a tap-to-talk button for people who do not use the hot key.
extension NotchPillView {
    var talkRow: TalkRowPresentation {
        TalkRowPresentation.resolve(
            voiceEnabled: settings.voiceEnabled,
            hasHandler: voice.actions.toggleTalk != nil,
            state: voiceState,
            permissions: voicePermissions,
            hotkey: settings.voiceHotkey,
            hotkeyStatus: voiceHotkeyStatus
        )
    }

    var hasTalkAction: Bool { talkRow.isVisible }

    /// A slim row in the privacy row's family. The panel is non-activating, so a click here
    /// never takes focus from the frontmost app.
    @ViewBuilder
    var talkAction: some View {
        let presentation = talkRow
        if let title = presentation.title {
            let shape = RoundedRectangle(cornerRadius: PillRadius.control, style: .continuous)
            Button {
                presentation.perform(on: voice)
                PillHaptics.play(.voiceTalkTap)
            } label: {
                HStack(spacing: PillSpace.s) {
                    Image(systemName: presentation.glyph.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(PillTextStyle.bodyStrong.font)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: PillSpace.xs)
                    if let caption = presentation.caption {
                        Text(caption)
                            .font(PillTextStyle.captionStrong.font)
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, PillSpace.s)
                .frame(height: PillRowHeight.slim)
                .background(shape.fill(reduceTransparency ? PillPalette.opaqueWhite(0.06) : Color.white.opacity(0.06)))
                .overlay(shape.stroke(Color.white.opacity(contrast == .increased ? 0.30 : 0.12), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PillButtonStyle(role: .row))
            .help(presentation == .allowAccess ? "Allow microphone and speech recognition" : "Start a voice command")
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(presentation.accessibilityHint ?? ""))
        }
    }
}
