import Foundation

/// Defaults and length caps of the provider settings. Not on `SettingsStore` so code off the
/// main actor can read them.
enum VoiceAIDefaults {
    static let baseURL = "https://api.openai.com/v1"
    static let sttModel = "gpt-4o-mini-transcribe"
    static let chatModel = "gpt-4o-mini"
    static let ttsModel = "gpt-4o-mini-tts"
    static let ttsVoice = "alloy"
    static let anthropicBaseURL = "https://api.anthropic.com"
    static let anthropicModel = "claude-haiku-4-5"
    static let maxBaseURLLength = 512
    static let maxModelLength = 128
    static let maxLanguageLength = 16
}

/// Which wire format answers the agent lane when it is not Hermes.
enum VoiceChatProviderKind: String, Sendable, Equatable {
    case openAICompatible
    case anthropic
}

/// Everything the AI providers need from Settings, as one value. The API keys are deliberately
/// not part of it: they are read from the Keychain at request time and never copied into a
/// long-lived value.
struct VoiceAIConfig: Equatable, Sendable {
    var chatProvider: VoiceChatProviderKind
    var baseURL: String
    var sttModel: String
    var chatModel: String
    var ttsModel: String
    var ttsVoice: String
    /// ISO-639-1 hint for speech-to-text; empty means auto-detect.
    var language: String
    var anthropicBaseURL: String
    var anthropicModel: String

    init(
        chatProvider: VoiceChatProviderKind = .openAICompatible,
        baseURL: String = VoiceAIDefaults.baseURL,
        sttModel: String = VoiceAIDefaults.sttModel,
        chatModel: String = VoiceAIDefaults.chatModel,
        ttsModel: String = VoiceAIDefaults.ttsModel,
        ttsVoice: String = VoiceAIDefaults.ttsVoice,
        language: String = "",
        anthropicBaseURL: String = VoiceAIDefaults.anthropicBaseURL,
        anthropicModel: String = VoiceAIDefaults.anthropicModel
    ) {
        self.chatProvider = chatProvider
        self.baseURL = baseURL.isEmpty ? VoiceAIDefaults.baseURL : baseURL
        self.sttModel = sttModel.isEmpty ? VoiceAIDefaults.sttModel : sttModel
        self.chatModel = chatModel.isEmpty ? VoiceAIDefaults.chatModel : chatModel
        self.ttsModel = ttsModel.isEmpty ? VoiceAIDefaults.ttsModel : ttsModel
        self.ttsVoice = ttsVoice.isEmpty ? VoiceAIDefaults.ttsVoice : ttsVoice
        self.language = language
        self.anthropicBaseURL = anthropicBaseURL.isEmpty ? VoiceAIDefaults.anthropicBaseURL : anthropicBaseURL
        self.anthropicModel = anthropicModel.isEmpty ? VoiceAIDefaults.anthropicModel : anthropicModel
    }

    /// An empty field in Settings means "use the default".
    @MainActor
    init(settings: SettingsStore) {
        self.init(
            chatProvider: settings.voiceAnswersProvider == .anthropic ? .anthropic : .openAICompatible,
            baseURL: settings.voiceAIBaseURL,
            sttModel: settings.voiceAISTTModel,
            chatModel: settings.voiceAIChatModel,
            ttsModel: settings.voiceAITTSModel,
            ttsVoice: settings.voiceAITTSVoice,
            language: settings.voiceAILanguage,
            anthropicBaseURL: settings.voiceAnthropicBaseURL,
            anthropicModel: settings.voiceAnthropicModel
        )
    }
}

/// The current `VoiceAIConfig`, shared between the main-actor coordinator (which writes it from
/// Settings right before each use) and the providers (which read it off the main actor).
/// Thread safety: the one stored value is guarded by `lock`.
final class VoiceAIConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: VoiceAIConfig

    init(_ value: VoiceAIConfig = VoiceAIConfig()) {
        self.value = value
    }

    func current() -> VoiceAIConfig {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ newValue: VoiceAIConfig) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Validation of the configured base URL. The rule: https anywhere, plain http only to this Mac
/// (`localhost`, `127.0.0.1`, `::1`), so a local LM Studio, Ollama or whisper server works
/// without TLS and nothing else can be reached in clear text. No credentials, query or fragment
/// in the URL (the key goes in a header, from the Keychain).
enum VoiceAIEndpoint {
    static func validate(_ raw: String) -> Result<URL, ProviderFailure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil
        else { return .failure(.endpointInvalid) }
        switch scheme {
        case "https":
            return .success(url)
        case "http":
            return isLoopback(host: host) ? .success(url) : .failure(.endpointInvalid)
        default:
            return .failure(.endpointInvalid)
        }
    }

    /// What a stored key is bound to: the lowercased host and the effective port
    /// (`api.openai.com:443`). Path changes keep the binding; host, port or scheme-default port
    /// changes break it.
    static func keyBinding(_ url: URL) -> String? {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty
        else { return nil }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    /// The binding of a configured base URL, or nil when the URL is not acceptable.
    static func keyBinding(base raw: String) -> String? {
        guard case .success(let url) = validate(raw) else { return nil }
        return keyBinding(url)
    }

    static func isLoopback(host: String) -> Bool {
        let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    /// `base` + `path`, e.g. `https://api.openai.com/v1` + `audio/transcriptions`.
    static func url(_ base: URL, _ path: String) -> URL {
        base.appendingPathComponent(path)
    }
}

/// Whether a request may be made right now, and with which key. A local endpoint may run
/// without a key; any other endpoint needs one.
enum VoiceAIReadiness {
    struct Ready: Equatable {
        var base: URL
        /// Nil only for a loopback endpoint with no stored key.
        var key: String?
    }

    /// Reads the key only when the endpoint is valid (a Keychain read can prompt).
    static func resolve(base raw: String, keys: VoiceAIKeyStoring) -> Result<Ready, ProviderFailure> {
        switch VoiceAIEndpoint.validate(raw) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let base):
            // Only a key saved for this exact host:port; a key bound elsewhere is never sent.
            let key = VoiceAIEndpoint.keyBinding(base).flatMap { keys.readKey(for: $0) }
            let local = VoiceAIEndpoint.isLoopback(host: base.host ?? "")
            if key == nil && !local { return .failure(.keyMissing) }
            return .success(Ready(base: base, key: key))
        }
    }

    /// Like `resolve` but without reading the secret (the preflight only needs to know a key exists).
    static func check(base raw: String, keys: VoiceAIKeyStoring) -> ProviderFailure? {
        switch VoiceAIEndpoint.validate(raw) {
        case .failure(let failure):
            return failure
        case .success(let base):
            let local = VoiceAIEndpoint.isLoopback(host: base.host ?? "")
            let bound = VoiceAIEndpoint.keyBinding(base).map { keys.hasKey(for: $0) } ?? false
            return bound || local ? nil : .keyMissing
        }
    }
}

/// Sizes and timeouts of the OpenAI-compatible lane, in one place.
enum VoiceAILimits {
    /// Upload sample rate (16 kHz mono, 16-bit PCM WAV).
    static let sampleRate = 16_000
    /// Audio kept for one capture: just over the 30 s hold cap. Later audio is dropped.
    static let maxAudioSeconds = 31.0
    static var maxSamples: Int { Int(Double(sampleRate) * maxAudioSeconds) }
    /// Below this the capture is treated as "no speech" and nothing is uploaded.
    static let minSamples = 3_200
    static let transcriptionTimeout: TimeInterval = 20
    /// The coordinator stretches the reducer's 5 s final-transcript watchdog to this for a
    /// cloud capture, so the upload has time to finish (the request timeout fires first).
    static let transcriptionWatchdog: TimeInterval = 25
    static let chatTimeout: TimeInterval = 60
    static let speechTimeout: TimeInterval = 30
    static let connectionTestTimeout: TimeInterval = 10
    /// JSON bodies (transcription, chat, model list) larger than this are rejected.
    static let maxJSONBytes = 1_000_000
    /// Spoken-reply audio larger than this falls back to the macOS voice.
    static let maxSpeechBytes = 8_000_000
    /// Upper bound of the chat answer; the reducer also caps the reply at 400 characters.
    static let maxReplyTokens = 200
}
