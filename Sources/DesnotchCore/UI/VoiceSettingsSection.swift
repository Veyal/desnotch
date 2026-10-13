import AppKit
import SwiftUI

@MainActor
struct VoiceSettingsSection: View {
    @ObservedObject var model: VoiceSessionModel
    @ObservedObject private var settings = SettingsStore.shared

    init(model: VoiceSessionModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsRows
        }
    }

    @ViewBuilder
    private var settingsRows: some View {
        SettingsHeader("Voice control", symbol: "mic.fill")
        Toggle("Voice control", isOn: $settings.voiceEnabled)
        SettingsNote("Off by default. Hold the shortcut to speak. Uses the microphone and on-device speech recognition unless you choose an AI provider below; audio is never saved.")
        if settings.voiceEnabled {
            permissionRow("Microphone", state: model.permissions.microphone)
            permissionRow("Speech Recognition", state: model.permissions.speech)
            if model.permissions.microphone == .notDetermined || model.permissions.speech == .notDetermined {
                Button("Allow Access…") { model.requestPermissions() }
            }
            if model.permissions.microphone == .denied {
                Button("Open Microphone Settings…") {
                    openPreferences("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
                .buttonStyle(.link)
            }
            if model.permissions.speech == .denied {
                Button("Open Speech Recognition Settings…") {
                    openPreferences("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
                }
                .buttonStyle(.link)
            }
            HStack(spacing: 8) {
                Text("Language")
                    .frame(width: 105, alignment: .leading)
                Picker("Language", selection: $settings.voiceLocale) {
                    ForEach(SettingsStore.supportedVoiceLocales, id: \.self) { identifier in
                        Text(VoiceSettingsWords.localeLabel(identifier)).tag(identifier)
                    }
                }
                .labelsHidden()
            }
            .font(.system(size: 11))
            SettingsNote("Indonesian needs the on-device dictation asset installed")
            HStack(spacing: 8) {
                Text("Shortcut")
                    .frame(width: 105, alignment: .leading)
                Picker("Shortcut", selection: $settings.voiceHotkey) {
                    ForEach(VoiceHotkeyChoice.allCases, id: \.self) { choice in
                        Text(VoiceSettingsWords.hotkeyLabel(choice)).tag(choice)
                    }
                }
                .labelsHidden()
            }
            .font(.system(size: 11))
            if model.hotkeyStatus == .unavailable && model.permissions != .unknown {
                SettingsNote("Another app uses this shortcut or the Stop shortcut ⌥⌘.", warning: true)
            }
            if settings.voiceHotkey == .optionCommandV {
                SettingsNote(VoiceSettingsWords.shortcutShadowNote)
            }
            Toggle("Speak replies", isOn: $settings.voiceTTSEnabled)
            SettingsNote("Silent in Privacy mode")
            Toggle("Lower other audio while listening", isOn: $settings.voiceDuckMedia)
            SettingsNote("Answers: anything that is not a built-in command can go to the agent chosen below (cloud).")
            VoiceAIProviderSettingsSection(model: model)
        }
    }

    private func permissionRow(_ title: String, state: VoicePermissionState) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: PillSpace.s)
            Text(VoiceSettingsWords.permissionText(state))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
    }

    private func openPreferences(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
