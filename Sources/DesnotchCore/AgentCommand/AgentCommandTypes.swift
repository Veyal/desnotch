import Foundation

public enum AgentCommandState: Equatable {
    case idle, transcribing, proposing, awaitingConfirmation, executing, finished, failed, cancelled

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .transcribing: return "Transcribing"
        case .proposing: return "Agent working"
        case .awaitingConfirmation: return "Needs confirmation"
        case .executing: return "Running command"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

public struct AgentCommandOutput: Equatable {
    public let stdout: String
    public let stderr: String
    public let truncated: Bool
    public init(stdout: String = "", stderr: String = "", truncated: Bool = false) {
        self.stdout = stdout; self.stderr = stderr; self.truncated = truncated
    }
}

public struct AgentCommandProposal: Equatable, Identifiable {
    public let id: UUID
    public let command: String
    public let arguments: [String]
    public init(id: UUID = UUID(), command: String, arguments: [String] = []) {
        self.id = id; self.command = command; self.arguments = arguments
    }
    public var argv: [String] { [command] + arguments }
    public var displayString: String {
        argv.map(Self.quotedForDisplay).joined(separator: " ")
    }

    public var redactedForDisplay: AgentCommandProposal {
        AgentCommandProposal(
            id: id,
            command: SecretRedactor.redactAndLimit(command, utf8ByteCap: 512),
            arguments: arguments.map { SecretRedactor.redactAndLimit($0, utf8ByteCap: 1_024) }
        )
    }

    private static func quotedForDisplay(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || "\"'\\".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum AgentCommandPolicyDecision: Equatable { case readOnly, confirmationRequired(reason: String), blocked(reason: String) }

public struct AgentCommandEvent: Equatable {
    public enum Kind: String { case status, output, proposal, error, complete }
    public let kind: Kind
    public let text: String?
    public let proposal: AgentCommandProposal?
    public init(kind: Kind, text: String? = nil, proposal: AgentCommandProposal? = nil) {
        self.kind = kind; self.text = text; self.proposal = proposal
    }
}

public enum AgentBackend: String, CaseIterable, Codable, Sendable {
    case codexCLI = "codex-cli"
    public static var `default`: AgentBackend { .codexCLI }
}

public protocol AgentCommandBackend {
    func stream(
        prompt: String,
        cwd: URL,
        timeout: TimeInterval,
        onEvent: @escaping @Sendable (AgentCommandEvent) -> Void
    ) async throws -> AgentCommandOutput
    func shutdown(timeout: TimeInterval)
}

public extension AgentCommandBackend {
    func shutdown(timeout: TimeInterval) {}
}
