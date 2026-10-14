import Foundation

/// The agent-lane backend for the OpenAI-compatible and Anthropic providers: one short spoken
/// answer per utterance, no tools. It runs behind the same reducer lane as Hermes, so the review
/// window, R54 (cloud only after the user ended the capture), the daily cap, the cloud badge,
/// Stop and the metadata-only audit all apply unchanged. Stop and Cancel cancel the request.
///
/// The turn is a loop over `ChatProvider` so a later package can add tool use through
/// `ChatToolHandling`; with the handler nil (this release) the loop runs exactly once.
/// Thread safety: the current turn's task is guarded by `lock`.
final class VoiceChatBackend: AgentBackend, @unchecked Sendable {
    /// Short and fixed: spoken-style, plain text, the user's own language. Bounded output keeps
    /// the answer inside the reducer's 400-character reply cap.
    static let systemPrompt = """
        You are the voice assistant in a Mac menu-bar app. Answer in one to three short \
        sentences of plain spoken text, under 350 characters. No markdown, lists, code or URLs. \
        Reply in the language the user spoke; if they mixed Indonesian and English, mix the same \
        way. You cannot control the computer; if asked to act, say you can only answer questions.
        """
    /// Tool round trips allowed in one turn once a tool handler exists.
    static let maxToolRounds = 4

    let id = "voice-chat"
    private let config: VoiceAIConfigBox
    private let providers: [ChatProvider]
    private let toolHandler: ChatToolHandling?
    private let lock = NSLock()
    private var current: Task<Void, Never>?

    init(config: VoiceAIConfigBox, providers: [ChatProvider], toolHandler: ChatToolHandling? = nil) {
        self.config = config
        self.providers = providers
        self.toolHandler = toolHandler
    }

    func preflight() async -> AgentPreflightResult {
        let snapshot = config.current()
        guard let provider = provider(for: snapshot.chatProvider) else { return .refused(.notImplemented) }
        if let failure = provider.readiness(snapshot) {
            return .refused(Self.preflightFailure(failure))
        }
        return .ready(profile: snapshot.chatProvider.rawValue)
    }

    func submit(_ utterance: String) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        let snapshot = config.current()
        let provider = provider(for: snapshot.chatProvider)
        let handler = toolHandler
        let task = Task {
            await Self.runTurn(
                utterance, config: snapshot, provider: provider, toolHandler: handler, emit: { continuation.yield($0) }
            )
            continuation.finish()
        }
        replaceCurrent(with: task)
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Never asks for approval (no tools), so there is nothing to answer.
    func respond(nonce: String, allow: Bool) async {}

    func cancelTurn() async {
        replaceCurrent(with: nil)
    }

    /// Cancelling the request is the whole stop: there is no process to signal.
    func emergencyStop() async -> EmergencyStopReport {
        replaceCurrent(with: nil)
        return EmergencyStopReport()
    }

    func shutdown() async {
        replaceCurrent(with: nil)
    }

    // MARK: - Turn

    static func runTurn(
        _ utterance: String,
        config: VoiceAIConfig,
        provider: ChatProvider?,
        toolHandler: ChatToolHandling?,
        emit: @Sendable (AgentEvent) -> Void
    ) async {
        guard let provider else {
            emit(.failed(.preflightRefused(.notImplemented)))
            return
        }
        if let failure = provider.readiness(config) {
            emit(.failed(.preflightRefused(preflightFailure(failure))))
            return
        }
        emit(.status("started"))
        var messages = [ChatMessage.user(utterance)]
        let tools = toolHandler?.tools ?? []
        for _ in 0...maxToolRounds {
            if Task.isCancelled {
                emit(.failed(.agentFailed("cancelled")))
                return
            }
            let request = ChatRequest(
                system: systemPrompt, messages: messages, tools: tools, maxTokens: VoiceAILimits.maxReplyTokens
            )
            switch await provider.complete(request, config: config) {
            case .cancelled:
                emit(.failed(.agentFailed("cancelled")))
                return
            case .failed(let failure):
                emit(.failed(.provider(failure)))
                return
            case .response(let response):
                if response.inputTokens > 0 || response.outputTokens > 0 {
                    emit(.usage(inputTokens: response.inputTokens, outputTokens: response.outputTokens, costMicros: 0))
                }
                let calls = response.toolUses
                guard let toolHandler, !calls.isEmpty else {
                    let reply = VoiceAIReplyShaper.shape(response.text)
                    emit(reply.isEmpty ? .failed(.provider(.badResponse)) : .finished(summary: reply))
                    return
                }
                messages.append(ChatMessage(role: .assistant, content: response.content))
                var results: [ChatContentBlock] = []
                for call in calls {
                    emit(.toolActivity(kind: call.name))
                    if Task.isCancelled {
                        emit(.failed(.agentFailed("cancelled")))
                        return
                    }
                    let outcome = await toolHandler.run(name: call.name, inputJSON: call.inputJSON)
                    results.append(.toolResult(toolUseID: call.id, content: outcome.content, isError: outcome.isError))
                }
                messages.append(ChatMessage(role: .user, content: results))
            }
        }
        emit(.failed(.stepBudgetExceeded))
    }

    static func preflightFailure(_ failure: ProviderFailure) -> PreflightFailure {
        failure == .endpointInvalid ? .providerEndpointInvalid : .providerKeyMissing
    }

    private func provider(for kind: VoiceChatProviderKind) -> ChatProvider? {
        providers.first { $0.kind == kind }
    }

    private func replaceCurrent(with task: Task<Void, Never>?) {
        let previous = swapCurrent(task)
        previous?.cancel()
    }

    private func swapCurrent(_ task: Task<Void, Never>?) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let previous = current
        current = task
        return previous
    }
}

/// Makes a model answer fit a spoken reply: no markdown symbols, one line, at most
/// `VoiceLimits.maxReplyCharacters`, cut at a sentence end when one is close.
enum VoiceAIReplyShaper {
    static func shape(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .filter { $0 != "`" && $0 != "#" && $0 != "*" }
        let words = stripped.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let line = words.joined(separator: " ")
        let cap = VoiceLimits.maxReplyCharacters
        guard line.count > cap else { return line }
        let head = String(line.prefix(cap))
        if let end = head.lastIndex(where: { ".!?".contains($0) }),
           head.distance(from: head.startIndex, to: end) >= cap / 2 {
            return String(head[...end])
        }
        let cut = String(head.prefix(cap - 1))
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }
}
