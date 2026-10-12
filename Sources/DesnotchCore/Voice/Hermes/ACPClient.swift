import Foundation

enum HermesACP {
    static let supportedProtocolVersions: Set<Int> = [1]
}

enum ACPLateEvent: Equatable, Sendable {
    case toolActivity(kind: String)
    case permissionRequest(nonce: String)
}

enum ACPClientError: Error, Equatable {
    case timeout
    case processExited
    case protocolMismatch
    case rpcError
    case sendFailed
}

/// Speaks ACP JSON-RPC on one transport. The reader lives as long as `lines`, not as long as one prompt.
final class ACPClient: @unchecked Sendable {
    let transport: ACPTransport
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let newNonce: @Sendable () -> String
    private let scheduler: HermesScheduling
    private let onLateEvent: @Sendable (ACPLateEvent) -> Void
    private let onPromptResult: @Sendable () -> Void
    private var mapper = HermesEventMapper()
    private var nextIdentifier = 1
    private var session = ""
    private var waiters: [Int: Waiter] = [:]
    private var early: [Int: Result<[String: Any], ACPClientError>] = [:]
    private var promptID: Int?
    private var awaitingPromptID: Int?
    private var promptContinuation: AsyncStream<AgentEvent>.Continuation?
    private var reader: Task<Void, Never>?

    private struct Waiter {
        var continuation: CheckedContinuation<[String: Any], Error>
        var task: HermesScheduledTask
    }

    init(
        transport: ACPTransport,
        now: @escaping @Sendable () -> Date,
        newNonce: @escaping @Sendable () -> String = { UUID().uuidString },
        scheduler: HermesScheduling,
        onLateEvent: @escaping @Sendable (ACPLateEvent) -> Void,
        onPromptResult: @escaping @Sendable () -> Void = {}
    ) {
        self.transport = transport
        self.now = now
        self.newNonce = newNonce
        self.scheduler = scheduler
        self.onLateEvent = onLateEvent
        self.onPromptResult = onPromptResult
        let stream = transport.lines
        reader = Task { [weak self] in
            for await data in stream {
                self?.handle(data)
            }
            self?.handleLinesEnded()
        }
    }

    var hasSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !session.isEmpty
    }

    func initialize() async throws {
        let id = allocateID()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": ["protocolVersion": 1, "clientCapabilities": [:] as [String: Any]]
        ]
        let result = try await roundTrip(body, id: id)
        guard let version = HermesJSON.int(result["protocolVersion"]) else {
            throw ACPClientError.protocolMismatch
        }
        if HermesPreflight.checkProtocol(version) != nil {
            throw ACPClientError.protocolMismatch
        }
    }

    func newSession() async throws -> String {
        let id = allocateID()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/new",
            "params": [
                "cwd": transport.workingDirectory.path,
                "mcpServers": [Any]()
            ]
        ]
        let result = try await roundTrip(body, id: id)
        guard let identifier = result["sessionId"] as? String, !identifier.isEmpty else {
            throw ACPClientError.rpcError
        }
        storeSession(identifier)
        return identifier
    }

    func prompt(_ utterance: String) throws -> AsyncStream<AgentEvent> {
        let id = allocateID()
        let pair = AsyncStream<AgentEvent>.makeStream()
        let sessionID = beginPrompt(id: id, continuation: pair.continuation)
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": utterance]]
            ]
        ]
        do {
            try send(body)
        } catch {
            endPromptStream()
            throw ACPClientError.sendFailed
        }
        return pair.stream
    }

    func respond(nonce: String, allow: Bool) {
        guard let reply = takeReply(nonce: nonce, allow: allow) else { return }
        try? send(reply)
    }

    func denyOutstanding() {
        for nonce in outstandingNonces() {
            respond(nonce: nonce, allow: false)
        }
    }

    func cancel() throws {
        let sessionID = currentSession()
        guard !sessionID.isEmpty else { return }
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": ["sessionId": sessionID]
        ]
        try send(body)
    }

    /// Ends the prompt event stream without a terminal event so later updates become late events.
    func detachPrompt() {
        endPromptStream()
    }

    private func roundTrip(_ body: [String: Any], id: Int) async throws -> [String: Any] {
        let task = scheduler.schedule(after: 20) { [weak self] in
            self?.fail(id: id, error: .timeout)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.park(id: id, continuation: continuation, task: task)
            do {
                try self.send(body)
            } catch {
                self.fail(id: id, error: .sendFailed)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let object = HermesJSON.object(data) else { return }
        if object["method"] != nil && object["id"] != nil && object["result"] == nil && object["error"] == nil {
            handleRequest(object)
            return
        }
        if object["id"] != nil && (object["result"] != nil || object["error"] != nil) {
            handleResponse(object)
            return
        }
        if (object["method"] as? String) == "session/update" {
            handleUpdate(object)
        }
    }

    private func handleRequest(_ object: [String: Any]) {
        let method = object["method"] as? String ?? ""
        guard let id = object["id"] else { return }
        if method == "session/request_permission" {
            let params = object["params"] as? [String: Any] ?? [:]
            let nonce = newNonce()
            let ingested = ingestPermission(params: params, id: id, nonce: nonce)
            deliver(ingested.events, latePermission: nonce)
            return
        }
        let error: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32601, "message": "Method not found"]
        ]
        try? send(error)
    }

    private func handleResponse(_ object: [String: Any]) {
        guard let id = HermesJSON.int(object["id"]) else { return }
        if isAwaitingPrompt(id) {
            let event: AgentEvent
            if object["error"] != nil {
                event = .failed(.agentFailed("rpc_error"))
            } else {
                let result = object["result"] as? [String: Any] ?? [:]
                let reason = result["stopReason"] as? String ?? "unknown"
                event = stopEvent(reason)
            }
            let continuation = takePromptContinuation()
            if let continuation {
                continuation.yield(event)
                continuation.finish()
            } else {
                onPromptResult()
            }
            return
        }
        if object["error"] != nil {
            succeed(id: id, result: .failure(.rpcError))
            return
        }
        let result = object["result"] as? [String: Any] ?? [:]
        succeed(id: id, result: .success(result))
    }

    private func handleUpdate(_ object: [String: Any]) {
        let update = (object["params"] as? [String: Any])?["update"] as? [String: Any] ?? [:]
        let ingested = ingestUpdate(update, at: now())
        deliver(ingested.events, latePermission: nil)
    }

    private func handleLinesEnded() {
        failAll(.processExited)
        endPromptStream()
    }

    private func deliver(_ events: [AgentEvent], latePermission: String?) {
        let continuation = promptSink()
        if let continuation {
            for event in events { continuation.yield(event) }
            return
        }
        for event in events {
            switch event {
            case .toolActivity(let kind):
                onLateEvent(.toolActivity(kind: kind))
            case .approvalNeeded(let card):
                onLateEvent(.permissionRequest(nonce: card.nonce))
            default:
                break
            }
        }
        if let latePermission, events.isEmpty {
            onLateEvent(.permissionRequest(nonce: latePermission))
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let data = HermesJSON.line(object) else { throw ACPClientError.sendFailed }
        do {
            try transport.send(line: data)
        } catch {
            throw ACPClientError.sendFailed
        }
    }

    private func allocateID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextIdentifier
        nextIdentifier += 1
        return id
    }

    private func storeSession(_ identifier: String) {
        lock.lock()
        session = identifier
        lock.unlock()
    }

    private func currentSession() -> String {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    private func beginPrompt(id: Int, continuation: AsyncStream<AgentEvent>.Continuation) -> String {
        lock.lock()
        mapper.beginPrompt()
        promptID = id
        awaitingPromptID = id
        promptContinuation = continuation
        let identifier = session
        lock.unlock()
        return identifier
    }

    private func promptSink() -> AsyncStream<AgentEvent>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return promptContinuation
    }

    private func takePromptContinuation() -> AsyncStream<AgentEvent>.Continuation? {
        lock.lock()
        let continuation = promptContinuation
        promptContinuation = nil
        promptID = nil
        lock.unlock()
        return continuation
    }

    private func isAwaitingPrompt(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let matches = awaitingPromptID == id
        if matches { awaitingPromptID = nil }
        return matches
    }

    private func endPromptStream() {
        let continuation = takePromptContinuation()
        continuation?.finish()
    }

    private func ingestUpdate(_ update: [String: Any], at: Date) -> HermesEventMapper.Ingest {
        lock.lock()
        let ingested = mapper.ingest(update: update, at: at)
        lock.unlock()
        return ingested
    }

    private func ingestPermission(params: [String: Any], id: Any, nonce: String) -> HermesEventMapper.Ingest {
        lock.lock()
        let ingested = mapper.ingestPermission(params: params, id: id, nonce: nonce)
        lock.unlock()
        return ingested
    }

    private func stopEvent(_ reason: String) -> AgentEvent {
        lock.lock()
        let event = mapper.stopEvent(reason: reason)
        lock.unlock()
        return event
    }

    private func takeReply(nonce: String, allow: Bool) -> [String: Any]? {
        lock.lock()
        let reply = mapper.reply(nonce: nonce, allow: allow)
        lock.unlock()
        return reply
    }

    private func outstandingNonces() -> [String] {
        lock.lock()
        let nonces = mapper.pendingNonces()
        lock.unlock()
        return nonces
    }

    private func park(id: Int, continuation: CheckedContinuation<[String: Any], Error>, task: HermesScheduledTask) {
        lock.lock()
        if let early = early.removeValue(forKey: id) {
            lock.unlock()
            task.cancel()
            switch early {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
            return
        }
        waiters[id] = Waiter(continuation: continuation, task: task)
        lock.unlock()
    }

    private func succeed(id: Int, result: Result<[String: Any], ACPClientError>) {
        lock.lock()
        guard let waiter = waiters.removeValue(forKey: id) else {
            early[id] = result
            lock.unlock()
            return
        }
        lock.unlock()
        waiter.task.cancel()
        switch result {
        case .success(let value): waiter.continuation.resume(returning: value)
        case .failure(let error): waiter.continuation.resume(throwing: error)
        }
    }

    private func fail(id: Int, error: ACPClientError) {
        succeed(id: id, result: .failure(error))
    }

    private func failAll(_ error: ACPClientError) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending.values {
            waiter.task.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }
}
