import Foundation

/// The opt-in AI providers the coordinator can switch to, built once per app run. Nil in the
/// coordinator means "on-device and Hermes only" (tests, smoke-test mode).
struct VoiceAIProviders {
    let config: VoiceAIConfigBox
    let recognizer: SpeechRecognizing
    let synthesizer: SpeechSynthesizing
    /// The answers backend for both the OpenAI-compatible and the Anthropic provider.
    let chatBackend: AgentBackend

    /// Production wiring: Keychain keys, the real microphone and player, and `fallback` (the
    /// macOS voice) behind the cloud reply voice. `tools` (the machine-control catalog) is
    /// offered to the answers model only while `voiceAgentToolsEnabled` is on; `audit` receives
    /// one metadata-only record per tool call.
    static func live(
        fallbackSynthesizer: SpeechSynthesizing,
        tools: ChatToolHandling? = nil,
        audit: AuditLogging? = nil
    ) -> VoiceAIProviders {
        let config = VoiceAIConfigBox()
        let session = VoiceAIHTTP.makeSession()
        let openAIKeys = KeychainVoiceAIKeyStore()
        let anthropicKeys = KeychainVoiceAIKeyStore(service: KeychainVoiceAIKeyStore.anthropicService)
        return VoiceAIProviders(
            config: config,
            recognizer: OpenAISpeechRecognizer(
                config: config, keys: openAIKeys, session: session, audio: EngineAudioCapture()
            ),
            synthesizer: OpenAISpeechSynthesizer(
                config: config, keys: openAIKeys, session: session,
                player: AVAudioDataPlayer(), fallback: fallbackSynthesizer
            ),
            chatBackend: VoiceChatBackend(
                config: config,
                providers: [
                    OpenAIChatProvider(keys: openAIKeys, session: session),
                    AnthropicChatProvider(keys: anthropicKeys, session: session)
                ],
                toolHandler: tools,
                audit: audit
            )
        )
    }
}

enum VoiceAIConnectionResult: Equatable, Sendable {
    case ok
    case failed(ProviderFailure)
}

/// Settings' "Test connection": one model-list request to the configured endpoint with the
/// stored key. Reports a category only; the key and the response body are never shown.
enum VoiceAIConnectionTester {
    enum Target: Equatable, Sendable {
        case openAICompatible
        case anthropic
    }

    static func test(
        _ target: Target, config: VoiceAIConfig, keys: VoiceAIKeyStoring, session: URLSession
    ) async -> VoiceAIConnectionResult {
        let base = target == .anthropic ? config.anthropicBaseURL : config.baseURL
        let ready: VoiceAIReadiness.Ready
        switch VoiceAIReadiness.resolve(base: base, keys: keys) {
        case .failure(let failure): return .failed(failure)
        case .success(let value): ready = value
        }
        let request = target == .anthropic
            ? anthropicModels(base: ready.base, key: ready.key)
            : OpenAIAudioWire.models(base: ready.base, key: ready.key)
        switch await VoiceAIHTTP.send(request, session: session, maxBytes: VoiceAILimits.maxJSONBytes) {
        case .ok: return .ok
        case .status(let status, _): return .failed(VoiceAIHTTP.classify(status: status))
        case .failed(let failure): return .failed(failure)
        case .cancelled: return .failed(.network)
        }
    }

    /// `GET {base}/v1/models` with the Anthropic headers.
    static func anthropicModels(base: URL, key: String?) -> URLRequest {
        var request = URLRequest(url: VoiceAIEndpoint.url(base, "v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = VoiceAILimits.connectionTestTimeout
        for (name, value) in AnthropicChatProvider.headers(key: key) where name != "content-type" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    static func message(_ result: VoiceAIConnectionResult) -> String {
        switch result {
        case .ok: return "Connected"
        case .failed(let failure): return VoiceFailure.provider(failure).userMessage
        }
    }
}
