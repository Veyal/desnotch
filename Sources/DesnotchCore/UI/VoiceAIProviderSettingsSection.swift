import SwiftUI

/// The Settings "Answers" picker folds two stored values into one choice: the agent lane switch
/// (`voiceHermesLane`, its stored name kept) and which backend answers (`voiceAnswersProvider`).
enum VoiceAnswersChoice: String, CaseIterable, Equatable {
    case off
    case hermes
    case openAICompatible
    case anthropic

    static func resolve(laneOn: Bool, provider: VoiceAnswersProvider) -> VoiceAnswersChoice {
        guard laneOn else { return .off }
        switch provider {
        case .hermes: return .hermes
        case .openAICompatible: return .openAICompatible
        case .anthropic: return .anthropic
        }
    }

    /// The two stored values this choice writes. Off keeps the last provider, so turning the
    /// lane back on returns to it.
    func stored(keeping provider: VoiceAnswersProvider) -> (laneOn: Bool, provider: VoiceAnswersProvider) {
        switch self {
        case .off: return (false, provider)
        case .hermes: return (true, .hermes)
        case .openAICompatible: return (true, .openAICompatible)
        case .anthropic: return (true, .anthropic)
        }
    }
}

/// Fixed Settings copy for the AI provider section. Never contains a key, URL or model reply.
enum VoiceAISettingsWords {
    static let intro = "Optional. Choose for each step whether it stays on this Mac or uses an AI service. The defaults keep everything on this Mac (answers off)."
    static let cloudNote = "When a step uses a provider, its audio (speech-to-text) or text (answers, spoken replies) is sent only to the endpoint below, and a cloud mark shows in the notch while that happens. desnotch saves none of it; the provider's own retention policy applies."
    static let anthropicNote = "Claude answers questions only. Anthropic has no speech API, so speech-to-text and spoken replies stay on this Mac or use the OpenAI-compatible provider."
    static let endpointInvalidNote = "Use an https URL. Plain http is allowed only for localhost, 127.0.0.1 or ::1."
    static let keyNote = "Stored in your Keychain. Never shown, exported or logged. Optional for a server on this Mac."
    static let languageNote = "Leave empty to auto-detect (best for mixed Indonesian and English)."
    static let speakRepliesOffNote = "Turn on Speak replies to hear answers."
    static let agentToolsTitle = "Let the agent control this Mac"
    static let agentToolsNote = "Off by default. When on, the AI can open apps and links, control media, volume and the timer, read files in your home folder, search file names and fetch public web pages on its own (rate-limited). Writing files, running shell commands, AppleScript or Shortcuts, reading the clipboard, and anything unusual wait for you to hold Approve on a card that shows the exact command, path or link. Network, credential and engagement locations are always refused. File contents and command output are sent to the AI provider."
    static let automationNote = "The first AppleScript that controls an app makes macOS ask for Automation permission."

    /// The machine-control switch exists only for the OpenAI-compatible and Claude answers.
    static func showsAgentTools(_ choice: VoiceAnswersChoice) -> Bool {
        choice == .openAICompatible || choice == .anthropic
    }

    static func speechLabel(_ provider: VoiceSpeechProvider) -> String {
        switch provider {
        case .onDevice: return "On this Mac"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    static func answersLabel(_ choice: VoiceAnswersChoice) -> String {
        switch choice {
        case .off: return "Off"
        case .hermes: return "Hermes agent"
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic: return "Claude (Anthropic)"
        }
    }

    static func replyLabel(_ provider: VoiceReplyProvider) -> String {
        switch provider {
        case .system: return "macOS voice"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// `bound` is where the stored key may be sent; `current` is the binding of the base URL in
    /// the field (nil while that URL is not acceptable). Only endpoint names, never the key.
    static func keyStatus(bound: String?, current: String?) -> String {
        guard let current else { return "Fix the base URL to save a key" }
        guard let bound else { return "No key saved" }
        if bound == current { return "Key saved for \(hostLabel(bound))" }
        return "Key saved for \(hostLabel(bound)) — re-enter for this host"
    }

    /// `api.openai.com:443` reads as `api.openai.com`; a non-default port stays visible.
    static func hostLabel(_ binding: String) -> String {
        if binding.hasSuffix(":443") || binding.hasSuffix(":80") {
            return String(binding[..<(binding.lastIndex(of: ":") ?? binding.endIndex)])
        }
        return binding
    }

    /// Nil when the URL is acceptable; empty means the default, which is.
    static func endpointNote(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if case .failure = VoiceAIEndpoint.validate(raw) { return endpointInvalidNote }
        return nil
    }
}

/// Settings > Voice control > AI provider. Shown only while voice is on.
@MainActor
struct VoiceAIProviderSettingsSection: View {
    @ObservedObject var model: VoiceSessionModel
    @ObservedObject private var settings = SettingsStore.shared
    private let openAIKeys: VoiceAIKeyStoring
    private let anthropicKeys: VoiceAIKeyStoring

    @State private var openAIKeyDraft = ""
    @State private var anthropicKeyDraft = ""
    @State private var openAIKeyBinding: String?
    @State private var anthropicKeyBinding: String?
    @State private var openAITest: String?
    @State private var anthropicTest: String?
    @State private var testing = false

    init(
        model: VoiceSessionModel,
        openAIKeys: VoiceAIKeyStoring = KeychainVoiceAIKeyStore(),
        anthropicKeys: VoiceAIKeyStoring = KeychainVoiceAIKeyStore(service: KeychainVoiceAIKeyStore.anthropicService)
    ) {
        self.model = model
        self.openAIKeys = openAIKeys
        self.anthropicKeys = anthropicKeys
    }

    private var answers: VoiceAnswersChoice {
        VoiceAnswersChoice.resolve(laneOn: settings.voiceHermesLane, provider: settings.voiceAnswersProvider)
    }

    private var usesOpenAI: Bool {
        settings.voiceSpeechProvider == .openAICompatible
            || answers == .openAICompatible
            || settings.voiceReplyProvider == .openAICompatible
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsHeader("AI provider", symbol: "cloud")
            SettingsNote(VoiceAISettingsWords.intro)
            pickerRow("Speech-to-text", selection: $settings.voiceSpeechProvider, options: VoiceSpeechProvider.allCases) {
                VoiceAISettingsWords.speechLabel($0)
            }
            pickerRow("Answers", selection: answersBinding, options: VoiceAnswersChoice.allCases) {
                VoiceAISettingsWords.answersLabel($0)
            }
            if answers == .hermes {
                SettingsNote("Requires the locked 'voice' Hermes profile.", warning: true)
            }
            if answers != .off {
                SettingsNote(VoiceSettingsWords.laneStatusText(model.hermesLaneStatus))
            }
            if VoiceAISettingsWords.showsAgentTools(answers) {
                Toggle(VoiceAISettingsWords.agentToolsTitle, isOn: $settings.voiceAgentToolsEnabled)
                    .font(.system(size: 11))
                SettingsNote(VoiceAISettingsWords.agentToolsNote, warning: settings.voiceAgentToolsEnabled)
                if settings.voiceAgentToolsEnabled {
                    SettingsNote(VoiceAISettingsWords.automationNote)
                }
            }
            pickerRow("Spoken replies", selection: $settings.voiceReplyProvider, options: VoiceReplyProvider.allCases) {
                VoiceAISettingsWords.replyLabel($0)
            }
            if settings.voiceReplyProvider == .openAICompatible && !settings.voiceTTSEnabled {
                SettingsNote(VoiceAISettingsWords.speakRepliesOffNote)
            }
            if usesOpenAI || answers == .anthropic {
                SettingsNote(VoiceAISettingsWords.cloudNote, warning: true)
            }
            if usesOpenAI {
                openAIFields
            }
            if answers == .anthropic {
                anthropicFields
            }
        }
        .onAppear(perform: refreshKeyStatus)
        .onChange(of: settings.voiceAIBaseURL) { _ in model.refreshAgentLane() }
        .onChange(of: settings.voiceAnthropicBaseURL) { _ in model.refreshAgentLane() }
    }

    @ViewBuilder
    private var openAIFields: some View {
        Text("OpenAI-compatible endpoint").font(.system(size: 12, weight: .semibold))
        textRow("Base URL", text: $settings.voiceAIBaseURL, prompt: SettingsStore.defaultVoiceAIBaseURL)
        if let note = VoiceAISettingsWords.endpointNote(settings.voiceAIBaseURL) {
            SettingsNote(note, warning: true)
        }
        keyRow(
            draft: $openAIKeyDraft,
            bound: openAIKeyBinding,
            current: VoiceAIEndpoint.keyBinding(base: VoiceAIConfig(settings: settings).baseURL),
            store: openAIKeys
        )
        if settings.voiceSpeechProvider == .openAICompatible {
            textRow("Speech model", text: $settings.voiceAISTTModel, prompt: SettingsStore.defaultVoiceAISTTModel)
            textRow("Language", text: $settings.voiceAILanguage, prompt: "auto")
            SettingsNote(VoiceAISettingsWords.languageNote)
        }
        if answers == .openAICompatible {
            textRow("Chat model", text: $settings.voiceAIChatModel, prompt: SettingsStore.defaultVoiceAIChatModel)
        }
        if settings.voiceReplyProvider == .openAICompatible {
            textRow("Voice model", text: $settings.voiceAITTSModel, prompt: SettingsStore.defaultVoiceAITTSModel)
            textRow("Voice", text: $settings.voiceAITTSVoice, prompt: SettingsStore.defaultVoiceAITTSVoice)
        }
        testRow(result: openAITest) { runTest(.openAICompatible) }
    }

    @ViewBuilder
    private var anthropicFields: some View {
        Text("Anthropic").font(.system(size: 12, weight: .semibold))
        SettingsNote(VoiceAISettingsWords.anthropicNote)
        textRow("Base URL", text: $settings.voiceAnthropicBaseURL, prompt: SettingsStore.defaultVoiceAnthropicBaseURL)
        if let note = VoiceAISettingsWords.endpointNote(settings.voiceAnthropicBaseURL) {
            SettingsNote(note, warning: true)
        }
        keyRow(
            draft: $anthropicKeyDraft,
            bound: anthropicKeyBinding,
            current: VoiceAIEndpoint.keyBinding(base: VoiceAIConfig(settings: settings).anthropicBaseURL),
            store: anthropicKeys
        )
        textRow("Model", text: $settings.voiceAnthropicModel, prompt: SettingsStore.defaultVoiceAnthropicModel)
        testRow(result: anthropicTest) { runTest(.anthropic) }
    }

    private var answersBinding: Binding<VoiceAnswersChoice> {
        Binding(
            get: { answers },
            set: { choice in
                let stored = choice.stored(keeping: settings.voiceAnswersProvider)
                settings.voiceAnswersProvider = stored.provider
                settings.voiceHermesLane = stored.laneOn
            }
        )
    }

    private func pickerRow<Option: Hashable>(
        _ title: String,
        selection: Binding<Option>,
        options: [Option],
        label: @escaping (Option) -> String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 105, alignment: .leading)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
        }
        .font(.system(size: 11))
    }

    private func textRow(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 105, alignment: .leading)
            VoiceAICommittedTextField(title: title, prompt: prompt, value: text)
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private func keyRow(
        draft: Binding<String>, bound: String?, current: String?, store: VoiceAIKeyStoring
    ) -> some View {
        let status = VoiceAISettingsWords.keyStatus(bound: bound, current: current)
        HStack(spacing: 8) {
            Text("API key")
                .frame(width: 105, alignment: .leading)
            SecureField("API key", text: draft, prompt: Text(status))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                // The key is saved for the base URL shown above and is only ever sent there.
                if let current, store.saveKey(draft.wrappedValue, for: current) {
                    draft.wrappedValue = ""
                    keysChanged()
                }
            }
            .disabled(current == nil || VoiceAIKeyFormat.normalized(draft.wrappedValue) == nil)
            if bound != nil {
                Button("Remove") {
                    store.deleteKey()
                    keysChanged()
                }
            }
        }
        .font(.system(size: 11))
        SettingsNote("\(status). \(VoiceAISettingsWords.keyNote)")
    }

    private func testRow(result: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button("Test Connection", action: action)
                .disabled(testing)
            if let result {
                Text(result)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
    }

    private func runTest(_ target: VoiceAIConnectionTester.Target) {
        testing = true
        let config = VoiceAIConfig(settings: settings)
        let keys = target == .anthropic ? anthropicKeys : openAIKeys
        Task { @MainActor in
            let session = VoiceAIHTTP.makeSession()
            let result = await VoiceAIConnectionTester.test(target, config: config, keys: keys, session: session)
            session.finishTasksAndInvalidate()
            let text = VoiceAIConnectionTester.message(result)
            if target == .anthropic {
                anthropicTest = text
            } else {
                openAITest = text
            }
            testing = false
        }
    }

    private func keysChanged() {
        refreshKeyStatus()
        model.refreshAgentLane()
    }

    private func refreshKeyStatus() {
        openAIKeyBinding = openAIKeys.boundEndpoint()
        anthropicKeyBinding = anthropicKeys.boundEndpoint()
    }
}

/// A text field that writes its value only on Return, on losing focus, or when Settings closes,
/// never per keystroke. A capture that starts mid-edit therefore never sees a half-typed base URL
/// (or model name), and each committed URL change re-checks the lane once.
@MainActor
struct VoiceAICommittedTextField: View {
    let title: String
    let prompt: String
    @Binding var value: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: value) { newValue in
                if !focused { draft = newValue }
            }
            .onAppear { draft = value }
            .onDisappear(perform: commit)
    }

    private func commit() {
        if draft != value { value = draft }
        draft = value
    }
}
