import Foundation

protocol HermesScheduledTask: Sendable {
    func cancel()
}

protocol HermesScheduling: Sendable {
    func schedule(after seconds: Double, _ action: @escaping @Sendable () -> Void) -> HermesScheduledTask
}

/// One `NSLock` around one integer. `bump` and `value` call nothing else.
final class HermesEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    func bump() {
        lock.lock()
        current += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

final class DispatchHermesScheduler: HermesScheduling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "desnotch.voice.hermes.timer")

    func schedule(after seconds: Double, _ action: @escaping @Sendable () -> Void) -> HermesScheduledTask {
        let task = DispatchHermesTask()
        let work = DispatchWorkItem { [weak task] in
            guard let task, !task.wasCancelled else { return }
            action()
        }
        task.store(work)
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
        return task
    }
}

private final class DispatchHermesTask: HermesScheduledTask, @unchecked Sendable {
    private let lock = NSLock()
    private var work: DispatchWorkItem?
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func store(_ work: DispatchWorkItem) {
        lock.lock()
        self.work = work
        let stop = cancelled
        lock.unlock()
        if stop { work.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let work = self.work
        lock.unlock()
        work?.cancel()
    }
}

/// The Hermes ACP lane. One instance for the life of the app. Constructing it spawns nothing.
/// Mutable turn state sits behind one `NSLock`, used only from synchronous helpers.
final class HermesAgentBackend: AgentBackend, @unchecked Sendable {
    let id = "hermes"
    private let lock = NSLock()
    private let epoch = HermesEpoch()
    private let locator: HermesLocator
    private let configReader: ConfigReading
    private let fileFlags: FileFlagReading
    private let processGuard: HermesProcessGuard
    private let scheduler: HermesScheduling
    private let now: @Sendable () -> Date
    private var client: ACPClient?
    private var userContinuation: AsyncStream<AgentEvent>.Continuation?
    private var userToken = 0
    private var userClosed = false
    private var promptInFlight = false
    private var turnToken = 0
    private var turnOpen = false
    private var killPending = false
    private var killTask: HermesScheduledTask?
    private var idleTask: HermesScheduledTask?
    private var approvalTasks: [String: HermesScheduledTask] = [:]

    init(
        locator: HermesLocator = HermesLocator(),
        configReader: ConfigReading = VoiceProfileConfigReader(),
        fileFlags: FileFlagReading = VoiceProfileFlagReader(),
        launch: ACPLaunch? = nil,
        pidFileDirectory: URL = FileAuditLogger.defaultDirectory(),
        transportFactory: @escaping @Sendable (ACPLaunch, URL) -> ACPTransport = {
            ProcessACPTransport(launch: $0, workingDirectoryRoot: $1)
        },
        scheduler: HermesScheduling = DispatchHermesScheduler(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.configReader = configReader
        self.fileFlags = fileFlags
        self.scheduler = scheduler
        self.now = now
        let resolvedLaunch = launch
        let resolvedLocator = locator
        processGuard = HermesProcessGuard(
            launch: { resolvedLaunch ?? resolvedLocator.hermesURL().map { ACPLaunch.hermes(path: $0) } },
            pidFileDirectory: pidFileDirectory,
            workingDirectoryRoot: FileManager.default.temporaryDirectory,
            transportFactory: transportFactory,
            now: now
        )
    }

    func preflight() async -> AgentPreflightResult {
        HermesPreflight.run(locator: locator, configReader: configReader, fileFlags: fileFlags)
    }

    func submit(_ utterance: String) -> AsyncStream<AgentEvent> {
        let mine = epoch.value
        let pair = AsyncStream<AgentEvent>.makeStream()
        if Self.isSlash(utterance) {
            pair.continuation.yield(.failed(.agentFailed("slash_prefix")))
            pair.continuation.finish()
            return pair.stream
        }
        if promptIsInFlight() {
            pair.continuation.yield(.failed(.agentFailed("busy")))
            pair.continuation.finish()
            return pair.stream
        }
        let token = storeUser(pair.continuation)
        Task { [weak self] in
            await self?.run(utterance, epoch: mine, user: token)
        }
        return pair.stream
    }

    func respond(nonce: String, allow: Bool) async {
        cancelApproval(nonce)
        storedClient()?.respond(nonce: nonce, allow: allow)
    }

    func cancelTurn() async {
        epoch.bump()
        storedClient()?.denyOutstanding()
        cancelApprovals()
        guard promptIsInFlight() else { return }
        try? storedClient()?.cancel()
        armKill()
        storedClient()?.detachPrompt()
        finishCurrentUser(.failed(.agentFailed("stop_cancelled")))
    }

    func emergencyStop() async -> EmergencyStopReport {
        epoch.bump()
        let report = await processGuard.hardStop { [weak self] in
            guard let self, self.promptIsInFlight() else { return }
            try? self.storedClient()?.cancel()
        }
        clearClient()
        finishCurrentUser(.failed(.agentFailed("stop_cancelled")))
        return report
    }

    func shutdown() async {
        epoch.bump()
        await processGuard.shutdown()
        clearClient()
        finishCurrentUser(.failed(.agentFailed("stop_cancelled")))
    }

    func terminateNow() {
        epoch.bump()
        processGuard.terminateNow()
        clearClient()
        finishCurrentUser(.failed(.agentFailed("stop_cancelled")))
    }

    private func run(_ utterance: String, epoch mine: Int, user token: Int) async {
        let turn = beginTurn()
        defer { endTurn(turn) }
        if consumeKill() {
            processGuard.terminateNow()
            clearClient()
        }
        let checked = HermesPreflight.run(locator: locator, configReader: configReader, fileFlags: fileFlags)
        if epoch.value != mine {
            finishUser(token, .failed(.agentFailed("stop_cancelled")))
            return
        }
        if case .refused(let reason) = checked {
            finishUser(token, .failed(.preflightRefused(reason)))
            return
        }
        let transport: ACPTransport
        do {
            transport = try processGuard.ensureRunning()
        } catch {
            finishUser(token, spawnFailure(error, epoch: mine))
            return
        }
        if epoch.value != mine {
            processGuard.terminate(transport)
            finishUser(token, .failed(.agentFailed("stop_cancelled")))
            return
        }
        guard let client = await session(on: transport, epoch: mine, user: token) else { return }
        if epoch.value != mine {
            processGuard.terminate(transport)
            finishUser(token, .failed(.agentFailed("stop_cancelled")))
            return
        }
        markPromptStarted()
        let events: AsyncStream<AgentEvent>
        do {
            events = try client.prompt(utterance)
        } catch {
            processGuard.terminate(transport)
            let code = epoch.value == mine ? "rpc_error" : "stop_cancelled"
            finishUser(token, .failed(.agentFailed(code)))
            return
        }
        emit(token, .status("started"))
        var terminal = false
        for await event in events {
            if userIsClosed(token) { break }
            if case .approvalNeeded(let card) = event {
                armApproval(card.nonce)
            }
            emit(token, event)
            if Self.isTerminal(event) {
                terminal = true
                disarmKill()
                finishUser(token, nil)
                break
            }
        }
        if !terminal && !userIsClosed(token) {
            let code = epoch.value == mine ? "process_exited" : "stop_cancelled"
            finishUser(token, .failed(.agentFailed(code)))
        }
    }

    private func session(on transport: ACPTransport, epoch mine: Int, user token: Int) async -> ACPClient? {
        if let existing = reusableClient(for: transport) { return existing }
        let created = makeClient(transport: transport)
        do {
            try await created.initialize()
        } catch {
            finishUser(token, handshakeFailure(error, epoch: mine, transport: transport))
            return nil
        }
        if epoch.value != mine {
            processGuard.terminate(transport)
            finishUser(token, .failed(.agentFailed("stop_cancelled")))
            return nil
        }
        do {
            _ = try await created.newSession()
        } catch {
            finishUser(token, handshakeFailure(error, epoch: mine, transport: transport))
            return nil
        }
        if epoch.value != mine {
            processGuard.terminate(transport)
            finishUser(token, .failed(.agentFailed("stop_cancelled")))
            return nil
        }
        processGuard.markHealthy()
        storeClient(created)
        return created
    }

    private func makeClient(transport: ACPTransport) -> ACPClient {
        ACPClient(
            transport: transport,
            now: now,
            scheduler: scheduler,
            onLateEvent: { [weak self] event in
                self?.handleLate(event, transport: transport)
            },
            onPromptResult: { [weak self] in
                self?.disarmKill()
            }
        )
    }

    private func handleLate(_ event: ACPLateEvent, transport: ACPTransport) {
        if case .permissionRequest(let nonce) = event {
            storedClient()?.respond(nonce: nonce, allow: false)
        }
        processGuard.terminate(transport)
    }

    private func spawnFailure(_ error: Error, epoch mine: Int) -> AgentEvent {
        if epoch.value != mine { return .failed(.agentFailed("stop_cancelled")) }
        if let error = error as? HermesGuardError, error == .backoff {
            return .failed(.agentFailed("backoff"))
        }
        return .failed(.agentFailed("spawn_failed"))
    }

    private func handshakeFailure(_ error: Error, epoch mine: Int, transport: ACPTransport) -> AgentEvent {
        let cancelled = epoch.value != mine
        processGuard.terminate(transport)
        if cancelled { return .failed(.agentFailed("stop_cancelled")) }
        guard let error = error as? ACPClientError else {
            return .failed(.agentFailed("handshake_timeout"))
        }
        switch error {
        case .timeout: return .failed(.agentFailed("handshake_timeout"))
        case .processExited: return .failed(.agentFailed("process_exited"))
        case .protocolMismatch: return .failed(.preflightRefused(.protocolMismatch))
        case .rpcError, .sendFailed: return .failed(.agentFailed("rpc_error"))
        }
    }

    private func armKill() {
        let task = scheduler.schedule(after: VoiceTiming.hardStopGrace) { [weak self] in
            self?.completeKill()
        }
        lock.lock()
        killPending = true
        let previous = killTask
        killTask = task
        lock.unlock()
        previous?.cancel()
    }

    private func completeKill() {
        guard consumeKill() else { return }
        processGuard.terminateNow()
        clearClient()
    }

    private func disarmKill() {
        lock.lock()
        killPending = false
        let task = killTask
        killTask = nil
        lock.unlock()
        task?.cancel()
    }

    private func consumeKill() -> Bool {
        lock.lock()
        let pending = killPending
        killPending = false
        let task = killTask
        killTask = nil
        lock.unlock()
        task?.cancel()
        return pending
    }

    private func armApproval(_ nonce: String) {
        let task = scheduler.schedule(after: VoiceTiming.approvalTimeout) { [weak self] in
            self?.storedClient()?.respond(nonce: nonce, allow: false)
        }
        lock.lock()
        let previous = approvalTasks[nonce]
        approvalTasks[nonce] = task
        lock.unlock()
        previous?.cancel()
    }

    private func cancelApproval(_ nonce: String) {
        lock.lock()
        let task = approvalTasks.removeValue(forKey: nonce)
        lock.unlock()
        task?.cancel()
    }

    private func cancelApprovals() {
        lock.lock()
        let tasks = Array(approvalTasks.values)
        approvalTasks.removeAll()
        lock.unlock()
        for task in tasks { task.cancel() }
    }

    private func armIdle() {
        let task = scheduler.schedule(after: 600) { [weak self] in
            self?.idleFired()
        }
        lock.lock()
        let previous = idleTask
        idleTask = task
        lock.unlock()
        previous?.cancel()
    }

    private func idleFired() {
        if turnIsOpen() {
            armIdle()
            return
        }
        processGuard.terminateNow()
        clearClient()
    }

    private func beginTurn() -> Int {
        lock.lock()
        turnToken += 1
        let token = turnToken
        turnOpen = true
        let task = idleTask
        idleTask = nil
        lock.unlock()
        task?.cancel()
        return token
    }

    private func endTurn(_ token: Int) {
        lock.lock()
        guard turnToken == token else {
            lock.unlock()
            return
        }
        turnOpen = false
        lock.unlock()
        armIdle()
    }

    private func reusableClient(for transport: ACPTransport) -> ACPClient? {
        guard let client = storedClient(), client.transport === transport, client.hasSession else { return nil }
        return client
    }

    private func storeClient(_ client: ACPClient) {
        lock.lock()
        self.client = client
        lock.unlock()
    }

    private func storedClient() -> ACPClient? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }

    private func clearClient() {
        lock.lock()
        client = nil
        lock.unlock()
    }

    private func storeUser(_ continuation: AsyncStream<AgentEvent>.Continuation) -> Int {
        lock.lock()
        userToken += 1
        let token = userToken
        userClosed = false
        userContinuation = continuation
        lock.unlock()
        return token
    }

    private func emit(_ token: Int, _ event: AgentEvent) {
        let continuation = openContinuation(token)
        continuation?.yield(event)
    }

    private func finishCurrentUser(_ event: AgentEvent) {
        lock.lock()
        let token = userToken
        lock.unlock()
        finishUser(token, event)
    }

    private func finishUser(_ token: Int, _ event: AgentEvent?) {
        lock.lock()
        if token != userToken || userClosed {
            lock.unlock()
            return
        }
        userClosed = true
        promptInFlight = false
        let continuation = userContinuation
        userContinuation = nil
        lock.unlock()
        if let event { continuation?.yield(event) }
        continuation?.finish()
    }

    private func openContinuation(_ token: Int) -> AsyncStream<AgentEvent>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        if token != userToken || userClosed { return nil }
        return userContinuation
    }

    private func userIsClosed(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != userToken || userClosed
    }

    private func markPromptStarted() {
        lock.lock()
        promptInFlight = true
        lock.unlock()
    }

    private func promptIsInFlight() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return promptInFlight
    }

    private func turnIsOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return turnOpen
    }

    private static func isSlash(_ utterance: String) -> Bool {
        guard let first = utterance.first(where: { !$0.isWhitespace }) else { return false }
        return first == "/"
    }

    private static func isTerminal(_ event: AgentEvent) -> Bool {
        switch event {
        case .finished, .failed: return true
        default: return false
        }
    }
}
