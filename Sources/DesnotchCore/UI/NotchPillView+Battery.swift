import SwiftUI

/// Battery row.
extension NotchPillView {
    func batteryRow(_ state: BatteryController.BatteryState) -> some View {
        HStack(spacing: PillRowLeading.gap) {
            PillBatteryGlyph(
                percent: state.percent,
                isCharging: state.isCharging,
                motion: motion,
                reduceTransparency: reduceTransparency
            )
            .frame(width: PillRowLeading.slot)
            Text(Self.batteryTitle(state))
                .font(PillTextStyle.bodyStrong.font)
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                .animation(motion.swap, value: state.powerStatus)
            Spacer(minLength: PillSpace.xs)
            // Polling only changes this when the integer changes, which is a real event.
            Text("\(state.percent)%")
                .font(PillTextStyle.body.font.monospacedDigit())
                .foregroundStyle(secondaryColor)
                .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
                .animation(motion.swap, value: state.percent)
        }
        .frame(minHeight: PillRowHeight.compact)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Battery \(state.percent) percent\(Self.batteryStatusSuffix(state))"))
    }

    static func batteryTitle(_ state: BatteryController.BatteryState) -> String {
        switch state.powerStatus {
        case .charging: return "Charging"
        case .pluggedIn: return "Plugged in"
        case .onBattery: return "Battery"
        }
    }

    static func batteryStatusSuffix(_ state: BatteryController.BatteryState) -> String {
        switch state.powerStatus {
        case .charging: return ", charging"
        case .pluggedIn: return ", plugged in"
        case .onBattery: return ""
        }
    }
}
