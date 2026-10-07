import SwiftUI

/// Privacy-mode toggle row.
extension NotchPillView {
    /// A row-sized switch. The knob slides with the tactile release spring (it snaps under
    /// Reduce Motion) and the state is also spelled out as "On"/"Off" so colour is never the
    /// only signal. Redaction itself happens as opacity crossfades on every redacted string.
    var privacyAction: some View {
        let on = settings.privacyModeEnabled
        let shape = RoundedRectangle(cornerRadius: PillRadius.control, style: .continuous)
        return Button {
            settings.privacyModeEnabled.toggle()
            PillHaptics.play(.privacyToggle)
        } label: {
            HStack(spacing: PillSpace.s) {
                Image(systemName: on ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? PillPalette.cyan.color : Color.white)
                    .frame(width: 16)
                    .contentTransition(.opacity)
                    .animation(motion.swap, value: on)
                    .accessibilityHidden(true)
                Text("Privacy mode")
                    .font(PillTextStyle.bodyStrong.font)
                    .foregroundStyle(.white)
                Spacer(minLength: PillSpace.xs)
                Text(on ? "On" : "Off")
                    .font(PillTextStyle.captionStrong.font)
                    .foregroundStyle(on ? PillPalette.cyan.color : secondaryColor)
                    .contentTransition(.opacity)
                    .animation(motion.swap, value: on)
                PillSwitch(isOn: on, motion: motion, reduceTransparency: reduceTransparency)
            }
            .padding(.horizontal, PillSpace.s)
            .frame(height: PillRowHeight.slim)
            .background(
                shape.fill(on
                    ? PillPalette.cyan.fill(alpha: 0.14, reduceTransparency: reduceTransparency)
                    : (reduceTransparency ? PillPalette.opaqueWhite(0.06) : Color.white.opacity(0.06)))
            )
            .overlay(
                shape.stroke(
                    on ? PillPalette.cyan.color.opacity(0.35) : Color.white.opacity(contrast == .increased ? 0.30 : 0.12),
                    lineWidth: 1
                )
            )
            .animation(motion.swap, value: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(PillButtonStyle(role: .row))
        .help(on ? "Show private details" : "Hide private details while sharing your screen")
        .accessibilityLabel(Text("Privacy mode"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .pillToggleSemantics(hint: "Toggles privacy mode")
    }
}
