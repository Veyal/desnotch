import SwiftUI

/// The Settings window content: one toggle per feature. Bound straight to
/// `SettingsStore.shared`; changes apply immediately (the pill re-renders and the
/// pollers check the flags on their next tick).
struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pill sections")
                .font(.headline)
            Toggle("Now playing (media controls)", isOn: $settings.nowPlayingEnabled)
            Toggle("AI agent activity", isOn: $settings.agentActivityEnabled)
            Toggle("Calendar glance", isOn: $settings.calendarEnabled)
            Toggle("Stuck-process detector", isOn: $settings.processMonitorEnabled)
            Toggle("File tray", isOn: $settings.trayEnabled)

            Divider()
                .padding(.vertical, 2)

            Text("Notch panel")
                .font(.headline)
            Picker("Visibility", selection: $settings.pillMode) {
                Text("Open on hover").tag(PillVisibilityMode.hoverAuto)
                Text("Always expanded").tag(PillVisibilityMode.alwaysOn)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            slider(
                "Collapse delay",
                value: $settings.hoverCollapseDelay,
                range: SettingsStore.hoverCollapseDelayRange,
                format: { String(format: "%.1fs", $0) }
            )
            .disabled(settings.pillMode == .alwaysOn)
            .opacity(settings.pillMode == .alwaysOn ? 0.4 : 1)

            slider(
                "Minimized width",
                value: $settings.minimizedWidth,
                range: SettingsStore.minimizedWidthRange,
                format: { "\(Int($0))pt" }
            )
            slider(
                "Minimized height",
                value: $settings.minimizedHeight,
                range: SettingsStore.minimizedHeightRange,
                format: { "\(Int($0))pt" }
            )
            slider(
                "Expanded width",
                value: $settings.expandedWidth,
                range: SettingsStore.expandedWidthRange,
                format: { "\(Int($0))pt" }
            )
            Text("Minimized size applies to screens without a physical notch; real hardware sets its own. Expanded height follows content.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 2)

            Text("Behavior")
                .font(.headline)
            Toggle("Volume on scroll", isOn: $settings.volumeScrollEnabled)
            Toggle("Notify when an agent needs you", isOn: $settings.notifyAgentNeedsYou)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(20)
        .frame(width: 300)
    }

    /// Label + slider + live value readout on one row, matching the pane's compact style.
    private func slider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 105, alignment: .leading)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 11))
    }
}
