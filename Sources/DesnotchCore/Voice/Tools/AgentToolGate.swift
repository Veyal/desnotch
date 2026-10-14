import Foundation

/// Waits for the user's answer to an agent card. The reducer answers through
/// `AgentBackend.respond(nonce:allow:)`; an unknown nonce is ignored. A wait ends `false` when
/// the turn is cancelled, the gate is closed (Stop, Cancel, shutdown) or the answer is deny.
/// Only a matching nonce from the reducer can approve: nothing the model or a tool returns
/// reaches this type. Thread safety: all state is guarded by `lock`.
final class AgentApprovalGate: @unchecked Sendable {
    private enum Slot {
        case waiting(CheckedContinuation<Bool, Never>?)
        case decided(Bool)
    }

    private let lock = NSLock()
    private var slots: [String: Slot] = [:]

    /// Registers a nonce BEFORE its card is emitted, so an answer that arrives before the
    /// wait starts is kept.
    func open(_ nonce: String) {
        lock.lock()
        slots[nonce] = .waiting(nil)
        lock.unlock()
    }

    func resolve(_ nonce: String, allow: Bool) {
        let waiter = settle(nonce, allow: allow)
        waiter?.resume(returning: allow)
    }

    func wait(_ nonce: String) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if let decided = attach(nonce, continuation) {
                    continuation.resume(returning: decided)
                }
            }
        } onCancel: {
            self.resolve(nonce, allow: false)
        }
    }

    /// Denies every open card (Stop, Cancel, shutdown).
    func denyAll() {
        let waiters = drain()
        for waiter in waiters {
            waiter.resume(returning: false)
        }
    }

    private func settle(_ nonce: String, allow: Bool) -> CheckedContinuation<Bool, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[nonce] else { return nil }
        switch slot {
        case .waiting(let continuation?):
            slots[nonce] = nil
            return continuation
        case .waiting(nil):
            slots[nonce] = .decided(allow)
            return nil
        case .decided:
            return nil
        }
    }

    /// The decided answer when there is one (the slot is consumed), otherwise nil after
    /// storing the continuation. A nonce that is not open (already denied by `denyAll`) is false.
    private func attach(_ nonce: String, _ continuation: CheckedContinuation<Bool, Never>) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        switch slots[nonce] {
        case .decided(let allow)?:
            slots[nonce] = nil
            return allow
        case .waiting?:
            slots[nonce] = .waiting(continuation)
            return nil
        case nil:
            return false
        }
    }

    private func drain() -> [CheckedContinuation<Bool, Never>] {
        lock.lock()
        defer { lock.unlock() }
        var waiters: [CheckedContinuation<Bool, Never>] = []
        for slot in slots.values {
            if case .waiting(let continuation?) = slot { waiters.append(continuation) }
        }
        slots = [:]
        return waiters
    }
}

/// Runs one model tool call through the tier gate, in this order:
/// 1. `propose` (no side effects). Invalid arguments go back to the model; nothing runs. Once a
///    tool that returns user data has run in the turn (`afterDataRead`), `open_url` and
///    `web_fetch` classify at T2 or higher without any DNS lookup, so a read cannot be carried
///    out in a URL's path or host name without the user seeing the full URL on a card.
/// 2. T0/T1: T1 takes a slot from the tool rate limiter (10 per minute); the start is reported
///    as `.toolActivity(label)` (R82) and the tool runs.
/// 3. T2: `.approvalNeeded` with a fresh nonce; the agent card shows the exact literal and
///    needs hold-to-approve (R85, R74). Only an approval for that nonce starts the tool, which
///    is then reported with its "(approved)" label (R82 consumes the approval).
/// 4. T3/T4: `.approvalNeeded` at that tier, which the reducer auto-denies without a card
///    (R84); nothing runs and the model is told the request is blocked.
/// Every call appends one metadata-only audit record (fixed tool code, tier, outcome code,
/// duration): never arguments, paths, commands, URLs or output.
/// Thread safety: the rate limiter is guarded by `lock`.
final class AgentToolGate: @unchecked Sendable {
    private let handler: ChatToolHandling
    private let approvals: AgentApprovalGate
    private let audit: AuditLogging?
    private let clock: VoiceClock
    private let makeNonce: @Sendable () -> String
    private let lock = NSLock()
    private var limiter = RateLimiter()

    init(
        handler: ChatToolHandling,
        approvals: AgentApprovalGate,
        audit: AuditLogging?,
        clock: VoiceClock = SystemVoiceClock(),
        makeNonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.handler = handler
        self.approvals = approvals
        self.audit = audit
        self.clock = clock
        self.makeNonce = makeNonce
    }

    var tools: [ChatToolDefinition] { handler.tools }

    static let deniedByUser = "The user did not approve this action. Do not retry it or work around it."
    static let blockedByPolicy = "Blocked by desnotch's safety policy: this action is not available by voice. Do not retry it or work around it; tell the user you can't do that here."
    static let rateLimited = "Too many actions in the last minute. Do not retry now; tell the user to try again shortly."

    func perform(
        id: String, name: String, inputJSON: String, afterDataRead: inout Bool, emit: @Sendable (AgentEvent) -> Void
    ) async -> ChatContentBlock {
        let started = clock.now()
        let context = ChatToolCallContext(afterDataRead: afterDataRead)
        let proposal = await handler.propose(name: name, inputJSON: inputJSON, context: context)
        if let reason = proposal.invalidReason {
            await record(proposal, outcome: "invalid", started: started)
            return .toolResult(toolUseID: id, content: "Invalid arguments: \(reason).", isError: true)
        }
        switch proposal.tier {
        case .t0, .t1:
            if proposal.tier == .t1, !consume(.t1) {
                await record(proposal, outcome: "rate_limited", started: started)
                return .toolResult(toolUseID: id, content: Self.rateLimited, isError: true)
            }
        case .t2:
            let nonce = makeNonce()
            approvals.open(nonce)
            emit(.approvalNeeded(request(proposal, nonce: nonce)))
            let allowed = await approvals.wait(nonce)
            if Task.isCancelled {
                await record(proposal, outcome: "cancelled", started: started)
                return .toolResult(toolUseID: id, content: "Stopped.", isError: true)
            }
            guard allowed else {
                await record(proposal, outcome: "denied", started: started)
                return .toolResult(toolUseID: id, content: Self.deniedByUser, isError: true)
            }
        case .t3, .t4:
            emit(.approvalNeeded(request(proposal, nonce: makeNonce())))
            await record(proposal, outcome: "blocked", started: started)
            return .toolResult(toolUseID: id, content: Self.blockedByPolicy, isError: true)
        }
        emit(.toolActivity(kind: proposal.stepLabel))
        let outcome = await handler.run(name: name, inputJSON: inputJSON, approvedTier: proposal.tier, context: context)
        if handler.revealsData(name: name) { afterDataRead = true }
        let cancelled = Task.isCancelled
        await record(proposal, outcome: cancelled ? "cancelled" : (outcome.isError ? "error" : "ok"), started: started,
                     outputBytes: outcome.content.utf8.count)
        let code = proposal.auditCode.hasPrefix("tool.") ? String(proposal.auditCode.dropFirst(5)) : "unknown"
        return .toolResult(toolUseID: id, content: AgentToolOutput.wrap(tool: code, outcome.content), isError: outcome.isError)
    }

    private func request(_ proposal: ChatToolProposal, nonce: String) -> ConfirmationRequest {
        ConfirmationRequest(
            nonce: nonce,
            tier: proposal.tier,
            source: .hermes,
            summary: proposal.summary,
            literal: proposal.literal,
            risk: proposal.risk,
            isTruncated: proposal.isTruncated,
            requiresSecondFactor: proposal.tier >= .t3
        )
    }

    private func consume(_ tier: VoiceTier) -> Bool {
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        return limiter.tryConsume(tier: tier, now: now) == .allowed
    }

    private func record(_ proposal: ChatToolProposal, outcome: String, started: Date, outputBytes: Int = 0) async {
        guard let audit else { return }
        let elapsed = max(0, clock.now().timeIntervalSince(started))
        await audit.append(AuditDraft(
            kind: .execute,
            lane: .hermes,
            tier: proposal.tier,
            decision: proposal.auditCode,
            outcome: outcome,
            counters: ["duration_ms": Int(elapsed * 1_000), "output_bytes": outputBytes]
        ))
    }
}
