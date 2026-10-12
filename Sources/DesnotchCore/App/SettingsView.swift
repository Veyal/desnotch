import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window content: one toggle per feature. Bound straight to
/// `SettingsStore.shared`; changes apply immediately (the pill re-renders and the
/// pollers check the flags on their next tick).
///
/// The pane is taller than many screens, so the content lives in a `ScrollView` and
/// the window is sized/resized against the visible screen frame (see
/// `AppDelegate.openSettings`) - a hosting view sized to `fittingSize` alone grew the
/// window past the screen and stranded the bottom rows unreachable.
struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    /// Present in the real app; nil keeps previews/tests independent of AX state.
    var notificationMirror: NotificationMirrorController?
    /// Present in the real app; reports whether the global shortcut registered.
    var globalHotKey: GlobalHotKeyController?
    /// Reopens the privacy-safe product guide. Nil keeps previews independent of AppKit windows.
    var onShowOnboarding: (() -> Void)?
    /// Present in the real app; nil keeps previews independent of the voice session.
    var voice: VoiceSessionModel? = nil
    /// Fixed pane width, shared with the window sizing so both stay in step.
    static let contentWidth: CGFloat = 300

    @State private var loginState = LaunchAtLogin.state
    @State private var loginError: String?
    @State private var transferMessage: String?
    @State private var transferFailed = false
    @State private var confirmingReset = false
    @State private var displays = ScreenSnapshot.current()

    var body: some View {
        ScrollView(.vertical) {
            content
                // Fills the scroll view's width, which is `contentWidth` minus the
                // scroller when the user runs "Show scroll bars: Always" - content
                // narrows instead of being clipped.
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.contentWidth)
        .onAppear { loginState = LaunchAtLogin.state }
        // Approving the login item happens in System Settings; pick that up on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginState = LaunchAtLogin.state
        }
        // Monitors come and go while this window is open; keep the display picker current.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = ScreenSnapshot.current()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onShowOnboarding {
                Button(action: onShowOnboarding) {
                    Label("Getting Started…", systemImage: "sparkles")
                }
                .buttonStyle(.link)

                Divider()
                    .padding(.vertical, 2)
            }

            SettingsHeader("Pill sections", symbol: "square.grid.2x2")
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
            if settings.musicIndicatorStyle == .equalizer {
                SettingsNote("The equalizer animates continuously while music plays, also over the artwork in the expanded pill. It's off by default for that reason, and Minimal/Reduce Motion falls back to the note.")
            }
            if settings.musicIndicatorStyle == .albumArt {
                SettingsNote("Album art falls back to the equalizer when a track has none, and is hidden by Privacy mode.")
            }
            Toggle("AI agent activity", isOn: $settings.agentActivityEnabled)
            Toggle("Show agent task titles", isOn: $settings.agentTaskTitlesEnabled)
                .disabled(!settings.agentActivityEnabled)
                .opacity(settings.agentActivityEnabled ? 1 : 0.4)
            SettingsNote("Shows a short hint of each session's first prompt instead of the project name. It is read from your local transcripts and is visible on screen; Privacy mode hides it. Off by default.")
            Toggle("Calendar glance", isOn: $settings.calendarEnabled)
            Toggle("Actionable reminders", isOn: $settings.remindersEnabled)
                .accessibilityHint(Text("Turning this on may request Reminders access"))
            SettingsNote("Shows the next due or overdue reminder. Add and complete reminders from the pill or status menu; access is requested only when enabled.")
            Toggle("Stuck-process detector", isOn: $settings.processMonitorEnabled)
            Toggle("File tray", isOn: $settings.trayEnabled)
            Toggle("Clipboard pocket (memory only)", isOn: $settings.clipboardHistoryEnabled)
            SettingsNote("Keeps up to 8 recent plain-text copies until desnotch quits. Password-manager and transient clipboard entries are skipped.")
            Toggle("Battery glance (MacBooks)", isOn: $settings.batteryEnabled)

            Divider()
                .padding(.vertical, 2)

            SettingsHeader("Notch panel", symbol: "rectangle.topthird.inset.filled")
            Picker("Visibility", selection: $settings.pillMode) {
                Text("Open on hover").tag(PillVisibilityMode.hoverAuto)
                Text("Always expanded").tag(PillVisibilityMode.alwaysOn)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Display")
                    .frame(width: 105, alignment: .leading)
                Picker("Display", selection: $settings.pillDisplay) {
                    ForEach(DisplayChoice.choices(for: displays, selected: settings.pillDisplay)) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                .labelsHidden()
            }
            .font(.system(size: 11))
            SettingsNote("Automatic prefers a display with a notch, then the main display. This choice stays on this Mac and is not part of exported settings.")

            HStack(spacing: 8) {
                Text("Animation")
                    .frame(width: 105, alignment: .leading)
                Picker("Animation style", selection: $settings.animationStyle) {
                    Text("Subtle").tag(AnimationStyle.subtle)
                    Text("Dynamic").tag(AnimationStyle.dynamic)
                    Text("Minimal").tag(AnimationStyle.minimal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .font(.system(size: 11))
            SettingsNote("Subtle: a smooth spring with a hint of overshoot. Dynamic: livelier overshoot and more blur. Minimal removes motion and matches macOS Reduce Motion, which always wins when it's on.")

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
            SettingsNote("Minimized size applies to screens without a physical notch; real hardware sets its own. Expanded height follows content.")

            Divider()
                .padding(.vertical, 2)

            SettingsHeader("Behavior", symbol: "hand.tap")
            Toggle("Volume on scroll", isOn: $settings.volumeScrollEnabled)
            Toggle("Drag timeline to seek", isOn: $settings.timelineSeekEnabled)
            Toggle("Mic/camera in-use dots", isOn: $settings.micCameraIndicatorEnabled)
            Toggle("Global shortcut to show the notch", isOn: $settings.globalHotkeyEnabled)
            if let globalHotKey {
                HotKeyNote(controller: globalHotKey, enabled: settings.globalHotkeyEnabled)
            } else {
                SettingsNote(Self.hotKeyExplanation(binding: .default, unavailable: false))
            }
            Toggle("Privacy mode", isOn: $settings.privacyModeEnabled)
            SettingsNote("Privacy mode hides song titles, agent task titles, event and reminder names, clipboard previews, and tray filenames — for screen sharing.")
            Toggle("Notify when an agent needs you", isOn: $settings.notifyAgentNeedsYou)
            Toggle("Notify when a process looks stuck", isOn: $settings.notifyStuckProcess)

            Divider()
                .padding(.vertical, 2)

            SettingsHeader("Notifications in the notch", symbol: "bell.badge")
            Toggle("Mirror notification banners", isOn: $settings.notificationMirrorEnabled)
            SettingsNote("Shows the app name and one line of each banner as it appears. Nothing is stored, and Privacy mode hides the text. Needs the Accessibility permission to read banners.")
            Toggle("Hide the macOS banner after mirroring", isOn: $settings.dismissSystemBanners)
                .disabled(!settings.notificationMirrorEnabled)
                .opacity(settings.notificationMirrorEnabled ? 1 : 0.4)
            SettingsNote("macOS has no supported way to stop a banner from appearing (and Do Not Disturb would hide it from the notch too), so desnotch closes it right after mirroring — expect a brief flash. The notification itself stays in Notification Center.")
            if let mirror = notificationMirror {
                NotificationPermissionStatus(controller: mirror)
            }

            if let voice {
                Divider()
                    .padding(.vertical, 2)
                VoiceSettingsSection(model: voice)
            }

            Divider()
                .padding(.vertical, 2)

            generalSection
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(20)
        // Extra breathing room so the last control never sits flush against the
        // window edge when scrolled to the bottom.
        .padding(.bottom, 8)
    }

    // MARK: Global shortcut

    fileprivate static func hotKeyExplanation(binding: HotKeyBinding, unavailable: Bool) -> String {
        let shortcut = binding.displayString
        if unavailable {
            return "\(shortcut) is already used by another app, so the shortcut is off. Show Notch in the status menu still works."
        }
        return "\(shortcut) holds the notch open until you press it again. It needs no extra permission. Show Notch in the status menu does the same."
    }

    /// Explains the shortcut and, observing the controller, flags a refused registration.
    private struct HotKeyNote: View {
        @ObservedObject var controller: GlobalHotKeyController
        let enabled: Bool

        var body: some View {
            let unavailable = enabled && controller.status == .unavailable
            SettingsNote(
                SettingsView.hotKeyExplanation(binding: controller.binding, unavailable: unavailable),
                warning: unavailable
            )
        }
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsHeader("General", symbol: "gearshape")
            Toggle("Launch at login", isOn: launchAtLoginBinding)
                .disabled(loginState == .unavailable)
            if let message = loginError ?? loginState.explanation {
                SettingsNote(message, warning: loginError != nil)
                if loginState == .requiresApproval {
                    Button("Open Login Items Settings") { LaunchAtLogin.openLoginItemsSettings() }
                        .controlSize(.small)
                }
            }
            Toggle("Check for updates", isOn: $settings.checkForUpdates)
            SettingsNote(VoiceSettingsWords.updateCheckNote)

            Text("Settings file")
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 4)
            HStack(spacing: 6) {
                Button("Export…") { exportSettings() }
                Button("Import…") { importSettings() }
                Button("Reset…") { confirmingReset = true }
            }
            .controlSize(.small)
            if confirmingReset {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Restore every setting to its default? Launch at login is not changed.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Reset settings", role: .destructive) {
                            settings.resetToDefaults()
                            confirmingReset = false
                            report("Settings restored to defaults.", failed: false)
                        }
                        Button("Cancel") { confirmingReset = false }
                    }
                    .controlSize(.small)
                }
            }
            if let transferMessage {
                SettingsNote(transferMessage, warning: transferFailed)
            }
            SettingsNote("The file holds only on/off switches, sizes, and style choices. It never includes event, reminder, agent, clipboard, or notification content.")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginState.isRegistered },
            set: { enabled in
                do {
                    loginState = try LaunchAtLogin.setEnabled(enabled)
                    loginError = nil
                } catch {
                    loginState = LaunchAtLogin.state
                    loginError = "Couldn't change launch at login: \(error.localizedDescription)"
                }
            }
        )
    }

    private func report(_ message: String, failed: Bool) {
        transferMessage = message
        transferFailed = failed
    }

    private func exportSettings() {
        confirmingReset = false
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "desnotch-settings.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportJSON().write(to: url, options: .atomic)
            report("Exported to \(url.lastPathComponent).", failed: false)
        } catch {
            report("Export failed: \(error.localizedDescription)", failed: true)
        }
    }

    private func importSettings() {
        confirmingReset = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Refuse oversized files before reading them into memory.
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= SettingsStore.maxImportBytes else { throw SettingsStore.ImportError.tooLarge }
            let result = try settings.importJSON(Data(contentsOf: url))
            var message = "Imported \(result.applied.count) setting\(result.applied.count == 1 ? "" : "s")."
            if !result.rejected.isEmpty {
                message += " Skipped \(result.rejected.count) unrecognized or invalid."
            }
            report(message, failed: false)
        } catch {
            report("Import failed: \(error.localizedDescription)", failed: true)
        }
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
                Label {
                    Text("Mirroring banners")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.system(size: 11))
            case .needsPermission:
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("Accessibility permission needed")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 6) {
                        Button("Grant Access…") { controller.requestPermission() }
                        Button("Open System Settings") {
                            NotificationMirrorController.openAccessibilitySettings()
                        }
                        Button("Check again") { controller.recheckPermission() }
                    }
                    .controlSize(.small)
                    SettingsNote("Enable desnotch under Privacy & Security › Accessibility, then it starts automatically.")
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
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(format(value.wrappedValue)))
            Text(format(value.wrappedValue))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .font(.system(size: 11))
    }

}

// MARK: - Shared pieces

/// A section title with a quiet leading glyph. The glyph is decorative; the title carries the
/// header trait so VoiceOver can jump between sections.
struct SettingsHeader: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Explanatory footnote under a control: 11pt secondary (system colors adapt to Increase
/// Contrast), red when it reports a problem. Wraps instead of truncating.
struct SettingsNote: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(warning ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
