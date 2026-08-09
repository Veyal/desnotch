import Combine
import CryptoKit
import Foundation

@MainActor
public final class AgentCommandController: ObservableObject {
    public static let transcriptByteCap = 8 * 1024
    public static let promptByteCap = 16 * 1024
    public static let confirmationLifetime: TimeInterval = 60

    @Published public private(set) var state: AgentCommandState = .idle
    @Published public private(set) var transcript: [String] = []
    @Published public private(set) var proposedCommand: AgentCommandProposal?
    @Published public private(set) var confirmationReason: String?
    @Published public private(set) var output = AgentCommandOutput()

    public private(set) var cwd: URL
    public private(set) var backendSelection: AgentBackend
    public let policy: AgentCommandPolicy
    public let audit: AgentCommandAudit?
    public private(set) var automaticReadOnly: Bool
    public private(set) var timeout: TimeInterval
    public private(set) var outputByteCap: Int

    private var backend: AgentCommandBackend
    private var agentTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commandRunner: AgentProcessRunner?
    private var confirmationExpiryTask: Task<Void, Never>?
    private var pendingProposal: AgentCommandProposal?
    private var confirmation: Confirmation?
    private var activeRunID: UUID?

    public init(
        cwd: URL,
        backend: AgentCommandBackend = CodexCLITransport(),
        backendSelection: AgentBackend = .default,
        policy: AgentCommandPolicy = AgentCommandPolicy(),
        audit: AgentCommandAudit? = nil,
        automaticReadOnly: Bool = true,
        timeout: TimeInterval = 120,
        outputByteCap: Int = 256 * 1024
    ) {
        self.cwd = cwd.standardizedFileURL
        self.backend = backend
        self.backendSelection = backendSelection
        self.policy = policy
        self.audit = audit
        self.automaticReadOnly = automaticReadOnly
        self.timeout = max(5, min(300, timeout))
        self.outputByteCap = max(4 * 1024, min(1024 * 1024, outputByteCap))
    }

    /// Apply settings before a new spoken request. Changing any execution boundary
    /// cancels the current run and invalidates a pending confirmation.
    public func configure(
        cwd: URL,
        backend: AgentBackend,
        automaticReadOnly: Bool,
        timeout: TimeInterval,
        outputByteCap: Int
    ) {
        cancel()
        self.cwd = cwd.standardizedFileURL
        backendSelection = backend
        self.backend = CodexCLITransport(runner: AgentProcessRunner(outputByteCap: outputByteCap))
        self.automaticReadOnly = automaticReadOnly
        self.timeout = max(5, min(300, timeout))
        self.outputByteCap = max(4 * 1024, min(1024 * 1024, outputByteCap))
        resetPublishedState()
    }

    public func submit(transcribedPrompt prompt: String) {
        cancel()
        resetPublishedState()
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed
            transcript = ["No spoken prompt was detected."]
            return
        }

        let runID = UUID()
        activeRunID = runID
        let safePrompt = SecretRedactor.redactAndLimit(trimmed, utf8ByteCap: Self.promptByteCap)
        appendTranscript("You: \(SecretRedactor.redactAndLimit(safePrompt, utf8ByteCap: 2_048))")
        state = .proposing
        audit?.record(event: "agent_request", outcome: "started", byteCount: trimmed.utf8.count)

        agentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await backend.stream(prompt: safePrompt, cwd: cwd, timeout: timeout) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.receive(event, runID: runID)
                    }
                }
                try Task.checkCancellation()
                await Task.yield()
                guard activeRunID == runID else { return }
                if result.truncated { appendTranscript("Agent output was truncated.") }
                if state == .proposing { state = .finished }
                agentTask = nil
                audit?.record(event: "agent_request", outcome: "finished")
            } catch is CancellationError {
                finishCancelled(runID: runID)
            } catch AgentProcessError.cancelled {
                finishCancelled(runID: runID)
            } catch AgentProcessError.timeout {
                guard activeRunID == runID else { return }
                appendTranscript("Agent request timed out.")
                state = .failed
                agentTask = nil
                audit?.record(event: "agent_request", outcome: "timeout")
            } catch {
                guard activeRunID == runID else { return }
                appendTranscript("Agent request failed.")
                state = .failed
                agentTask = nil
                audit?.record(event: "agent_request", outcome: "failed")
            }
        }
    }

    public func confirm() {
        guard let pendingProposal, let confirmation,
              confirmation.proposalID == pendingProposal.id,
              confirmation.cwd == cwd.standardizedFileURL.path,
              confirmation.backend == backendSelection,
              confirmation.digest == Self.digest(pendingProposal),
              confirmation.expiresAt > Date()
        else {
            invalidateConfirmation(expired: true)
            return
        }
        invalidateConfirmation(expired: false)
        execute(pendingProposal)
    }

    public func cancel() {
        agentTask?.cancel()
        commandTask?.cancel()
        agentTask = nil
        commandTask = nil
        confirmationExpiryTask?.cancel()
        confirmationExpiryTask = nil
        confirmation = nil
        pendingProposal = nil
        activeRunID = nil
        if state != .idle { state = .cancelled }
        audit?.record(event: "agent_action", outcome: "cancelled")
    }

    public func clear() {
        cancel()
        resetPublishedState()
    }

    /// Signal-safe callers still enter through the main actor, then wait here for
    /// the owned planner/command process groups to drain before the app exits.
    public func shutdownOwnedProcesses(timeout: TimeInterval = 2) {
        agentTask?.cancel()
        commandTask?.cancel()
        backend.shutdown(timeout: timeout)
        commandRunner?.shutdown(timeout: timeout)
        agentTask = nil
        commandTask = nil
        commandRunner = nil
        activeRunID = nil
    }

    public func failConfiguration(_ message: String) {
        cancel()
        resetPublishedState()
        state = .failed
        transcript = [SecretRedactor.redactAndLimit(message, utf8ByteCap: 512)]
    }

    private func receive(_ event: AgentCommandEvent, runID: UUID) {
        guard activeRunID == runID else { return }
        if let text = event.text, !text.isEmpty {
            appendTranscript(SecretRedactor.redactAndLimit(text, utf8ByteCap: 4_096))
        }
        if let proposal = event.proposal { receive(proposal) }
        if event.kind == .error { state = .failed }
    }

    private func receive(_ proposal: AgentCommandProposal) {
        // A streamed agent message can be delivered as both `item.updated` and
        // `item.completed`. Bind at most one proposal to each request so an
        // automatic read-only command cannot execute twice.
        guard state == .proposing, pendingProposal == nil, commandTask == nil else { return }
        let decision = policy.decision(for: proposal, cwd: cwd)
        pendingProposal = proposal
        proposedCommand = proposal.redactedForDisplay
        switch decision {
        case .readOnly where automaticReadOnly:
            confirmationReason = nil
            execute(proposal)
        case .readOnly:
            awaitConfirmation(for: proposal, reason: "Automatic read-only commands are disabled.")
        case .confirmationRequired(let reason):
            awaitConfirmation(for: proposal, reason: reason)
        case .blocked(let reason):
            pendingProposal = nil
            confirmationReason = reason
            state = .failed
            audit?.record(event: "command_proposal", outcome: "blocked", policy: "blocked")
        }
    }

    private func awaitConfirmation(for proposal: AgentCommandProposal, reason: String) {
        let expiry = Date().addingTimeInterval(Self.confirmationLifetime)
        confirmation = Confirmation(
            proposalID: proposal.id,
            digest: Self.digest(proposal),
            cwd: cwd.standardizedFileURL.path,
            backend: backendSelection,
            expiresAt: expiry
        )
        confirmationReason = reason
        state = .awaitingConfirmation
        confirmationExpiryTask?.cancel()
        confirmationExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.confirmationLifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.invalidateConfirmation(expired: true)
        }
        audit?.record(event: "command_proposal", outcome: "confirmation_required", policy: "confirmation")
    }

    private func invalidateConfirmation(expired: Bool) {
        confirmationExpiryTask?.cancel()
        confirmationExpiryTask = nil
        confirmation = nil
        pendingProposal = nil
        if expired, state == .awaitingConfirmation {
            confirmationReason = "Confirmation expired. Ask the agent again."
            state = .failed
            audit?.record(event: "command_confirmation", outcome: "expired")
        }
    }

    private func execute(_ proposal: AgentCommandProposal) {
        guard let executable = Self.findExecutable(proposal.command) else {
            state = .failed
            confirmationReason = "The proposed executable is not installed."
            audit?.record(event: "command_execute", outcome: "missing_executable")
            return
        }
        let runID = activeRunID ?? UUID()
        activeRunID = runID
        state = .executing
        output = AgentCommandOutput()
        audit?.record(event: "command_execute", outcome: "started")
        let runner = AgentProcessRunner(outputByteCap: outputByteCap)
        commandRunner = runner
        commandTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runner.run(
                    executable: executable,
                    arguments: proposal.arguments,
                    cwd: cwd,
                    timeout: timeout
                )
                try Task.checkCancellation()
                guard activeRunID == runID else { return }
                output = AgentCommandOutput(
                    stdout: SecretRedactor.redactAndLimit(result.stdout, utf8ByteCap: outputByteCap),
                    stderr: SecretRedactor.redactAndLimit(result.stderr, utf8ByteCap: outputByteCap),
                    truncated: result.truncated
                )
                state = result.exitCode == 0 ? .finished : .failed
                commandTask = nil
                commandRunner = nil
                pendingProposal = nil
                audit?.record(
                    event: "command_execute",
                    outcome: result.exitCode == 0 ? "finished" : "nonzero_exit",
                    byteCount: result.stdout.utf8.count + result.stderr.utf8.count
                )
            } catch AgentProcessError.timeout {
                commandFailed("Command timed out.", outcome: "timeout", runID: runID)
            } catch is CancellationError {
                finishCancelled(runID: runID)
            } catch AgentProcessError.cancelled {
                finishCancelled(runID: runID)
            } catch {
                commandFailed("Command failed to start.", outcome: "failed", runID: runID)
            }
        }
    }

    private func commandFailed(_ message: String, outcome: String, runID: UUID) {
        guard activeRunID == runID else { return }
        output = AgentCommandOutput(stderr: message)
        state = .failed
        commandTask = nil
        commandRunner = nil
        audit?.record(event: "command_execute", outcome: outcome)
    }

    private func finishCancelled(runID: UUID) {
        guard activeRunID == runID else { return }
        state = .cancelled
        agentTask = nil
        commandTask = nil
        commandRunner = nil
        audit?.record(event: "agent_action", outcome: "cancelled")
    }

    private func appendTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        transcript.append(text)
        while transcript.joined(separator: "\n").utf8.count > Self.transcriptByteCap,
              transcript.count > 1 {
            transcript.removeFirst()
        }
        if transcript.joined(separator: "\n").utf8.count > Self.transcriptByteCap,
           let last = transcript.last {
            transcript = [SecretRedactor.redactAndLimit(last, utf8ByteCap: Self.transcriptByteCap)]
        }
    }

    private func resetPublishedState() {
        state = .idle
        transcript = []
        proposedCommand = nil
        confirmationReason = nil
        output = AgentCommandOutput()
    }

    private static func findExecutable(_ command: String) -> URL? {
        if command.contains("/") {
            let url = URL(fileURLWithPath: command).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return ["/bin/", "/usr/bin/", "/opt/homebrew/bin/", "/usr/local/bin/"]
            .map { URL(fileURLWithPath: $0 + command) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func digest(_ proposal: AgentCommandProposal) -> String {
        let joined = proposal.argv.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Confirmation {
        let proposalID: UUID
        let digest: String
        let cwd: String
        let backend: AgentBackend
        let expiresAt: Date
    }
}
