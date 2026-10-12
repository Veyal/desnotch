import Foundation

// MARK: - Honest stubs (frozen, see VoiceTypes.swift)
//
// Compiling placeholders for every seam. None of them pretends to work: each returns a typed
// `.unavailable` failure, reports `isLocked == true`, or refuses. A work package replaces the
// stub by writing the real type in its own file; the stub stays only as a test double and
// as the default when a real implementation cannot be constructed.

/// A recognizer that is not installed. Every capture fails with `.unavailable(.recognizer)`.
final class UnavailableRecognizer: SpeechRecognizing {
    init() {}

    func start(localeIdentifier: String, contextualStrings: [String]) -> AsyncStream<SpeechEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(.unavailable(.recognizer)))
            continuation.finish()
        }
    }

    func endAudio() {}
    func cancel() {}
}

/// A synthesizer that is not installed: never speaks, reports "not finished".
final class UnavailableSynthesizer: SpeechSynthesizing {
    init() {}
    func speak(_ text: String, localeIdentifier: String) async -> Bool { false }
    func stop() {}
}

/// An executor that is not installed: every intent fails with `.unavailable(.executor)`.
@MainActor
final class UnavailableLocalExecutor: LocalExecuting {
    init() {}
    func execute(_ intent: LocalIntent) async -> LocalExecutionResult {
        .failure(.unavailable(.executor))
    }
}

/// The Hermes lane that is switched off or not built yet. Preflight always refuses.
final class NullBackend: AgentBackend {
    init() {}
    var id: String { "null" }

    func preflight() async -> AgentPreflightResult {
        .refused(.notImplemented)
    }

    func submit(_ utterance: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(.unavailable(.backend)))
            continuation.finish()
        }
    }

    func respond(nonce: String, allow: Bool) async {}
    func cancelTurn() async {}
    func emergencyStop() async -> EmergencyStopReport { EmergencyStopReport() }
    func shutdown() async {}
}

/// An audit log that cannot write. `append` returns false, so T2+ actions are refused.
final class NullAuditLogger: AuditLogging {
    init() {}
    func append(_ draft: AuditDraft) async -> Bool { false }
    func verify() async -> AuditVerification {
        AuditVerification(isValid: false, recordCount: 0, firstBrokenSeq: nil, headHash: "")
    }
}

/// A file writer that refuses every operation.
struct UnavailableFileWriter: FileWriting {
    struct Unavailable: Error, Equatable {}
    init() {}
    func ensureDirectory(_ url: URL) throws { throw Unavailable() }
    func appendLine(_ line: String, to url: URL) throws { throw Unavailable() }
    func readLines(from url: URL) throws -> [String] { throw Unavailable() }
    func restrictToOwner(_ url: URL) throws { throw Unavailable() }
    func fileSize(_ url: URL) throws -> Int { throw Unavailable() }
    func moveItem(at source: URL, to destination: URL) throws { throw Unavailable() }
}

/// No key source: `start()` reports unavailable and the stream stays silent.
@MainActor
final class UnavailablePushToTalk: PushToTalkSource {
    let events: AsyncStream<PushToTalkEvent>
    private let continuation: AsyncStream<PushToTalkEvent>.Continuation

    init() {
        var captured: AsyncStream<PushToTalkEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func start() -> PushToTalkStatus { .unavailable }
    func stop() { continuation.finish() }
    func setCancelKeyArmed(_ armed: Bool) {}
}

/// Lock state that is unknown: reports locked, so voice commands are refused (fail closed).
@MainActor
final class UnknownLockState: LockStateProviding {
    var isLocked: Bool { true }
    let changes: AsyncStream<Bool>

    init() {
        changes = AsyncStream { $0.finish() }
    }
}

/// A ducker that does nothing, by design: ducking is a nicety, not a safety control.
@MainActor
final class NoopMediaDucker: MediaDucking {
    init() {}
    func duck() {}
    func restore() {}
}

/// Permissions that cannot be determined.
@MainActor
final class UnavailablePermissions: VoicePermissionProviding {
    init() {}
    func status() -> VoicePermissionStatus { .unknown }
    func request() async -> VoicePermissionStatus { .unknown }
}

/// A cue player that stays silent, by design.
@MainActor
final class NoopCuePlayer: VoiceCuePlaying {
    init() {}
    func play(_ cue: VoiceCue) {}
}
