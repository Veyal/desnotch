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

            Text("Behavior")
                .font(.headline)
            Toggle("Volume on scroll", isOn: $settings.volumeScrollEnabled)
            Toggle("Notify when an agent needs you", isOn: $settings.notifyAgentNeedsYou)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(20)
        .frame(width: 280)
    }
}
