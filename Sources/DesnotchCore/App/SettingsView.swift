import SwiftUI

/// The Settings window content: one toggle per feature. Bound straight to
/// `SettingsStore.shared`; changes apply immediately (the pill re-renders and the
/// pollers check the flags on their next tick).
struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    /// Present in the real app; nil keeps previews/tests independent of AX state.
    var notificationMirror: NotificationMirrorController?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pill sections")
                .font(.headline)
            Toggle("Now playing (media controls)", isOn: $settings.nowPlayingEnabled)
            HStack(spacing: 8) {
                Text("Music indicator")
                    .frame(width: 105, alignment: .leading)
                // labelsHidden only hides the visual duplicate; the Picker's title
                // stays as its accessibility label for VoiceOver.
                Picker("Music indicator style", selection: $settings.musicIndicatorStyle) {
                    Text("Equalizer").tag(MusicIndicatorStyle.equalizer)
                    Text("Note").tag(MusicIndicatorStyle.note)
                    Text("Album art").tag(MusicIndicatorStyle.albumArt)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .font(.system(size: 11))
            .disabled(!settings.nowPlayingEnabled)
            .opacity(settings.nowPlayingEnabled ? 1 : 0.4)
            if settings.musicIndicatorStyle == .albumArt {
                Text("Album art falls back to the equalizer when a track has none, and is hidden by Privacy mode.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("AI agent activity", isOn: $settings.agentActivityEnabled)
            Toggle("Calendar glance", isOn: $settings.calendarEnabled)
            Toggle("Stuck-process detector", isOn: $settings.processMonitorEnabled)
            Toggle("File tray", isOn: $settings.trayEnabled)
            Toggle("Battery glance (MacBooks)", isOn: $settings.batteryEnabled)

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
            Toggle("Drag timeline to seek", isOn: $settings.timelineSeekEnabled)
            Toggle("Mic/camera in-use dots", isOn: $settings.micCameraIndicatorEnabled)
            Toggle("Privacy mode", isOn: $settings.privacyModeEnabled)
            Text("Privacy mode hides song titles, agent task titles, event names, and tray filenames — for screen sharing.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Notify when an agent needs you", isOn: $settings.notifyAgentNeedsYou)

            Divider()
                .padding(.vertical, 2)

            Text("Notifications in the notch")
                .font(.headline)
            Toggle("Mirror notification banners", isOn: $settings.notificationMirrorEnabled)
            Text("Shows the app name and one line of each banner as it appears. Nothing is stored, and Privacy mode hides the text. Needs the Accessibility permission to read banners.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Hide the macOS banner after mirroring", isOn: $settings.dismissSystemBanners)
                .disabled(!settings.notificationMirrorEnabled)
                .opacity(settings.notificationMirrorEnabled ? 1 : 0.4)
            Text("macOS has no supported way to stop a banner from appearing (and Do Not Disturb would hide it from the notch too), so desnotch closes it right after mirroring — expect a brief flash. The notification itself stays in Notification Center.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let mirror = notificationMirror {
                NotificationPermissionStatus(controller: mirror)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(20)
        .frame(width: 300)
    }

    /// Permission status + grant/retry flow for the notification mirror. Three states:
    /// hidden (feature off), "needs permission" with Grant/Open/Check-again actions,
    /// and an all-clear line once active. The controller also self-rechecks every 5s
    /// while denied, so granting in System Settings lights up without a relaunch.
    private struct NotificationPermissionStatus: View {
        @ObservedObject var controller: NotificationMirrorController

        var body: some View {
            switch controller.permission {
            case .off:
                EmptyView()
            case .active:
                Label("Mirroring banners", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            case .needsPermission:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Accessibility permission needed", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.yellow)
                    HStack(spacing: 6) {
                        Button("Grant Access…") { controller.requestPermission() }
                        Button("Open System Settings") {
                            NotificationMirrorController.openAccessibilitySettings()
                        }
                        Button("Check again") { controller.recheckPermission() }
                    }
                    .controlSize(.small)
                    Text("Enable desnotch under Privacy & Security › Accessibility, then it starts automatically.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
