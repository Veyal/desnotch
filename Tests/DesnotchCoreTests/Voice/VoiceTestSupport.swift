import Foundation
import XCTest
@testable import DesnotchCore

// Shared test doubles for the voice work packages. Owned by the base commit and frozen:
// a work package that needs a different double writes its own in its own test file.

/// A clock the test moves by hand.
final class FakeVoiceClock: VoiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// A recognizer that replays a fixed event script.
final class ScriptedRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let script: [SpeechEvent]
    private var _endAudioCalls = 0
    private var _cancelCalls = 0

    init(script: [SpeechEvent]) {
        self.script = script
    }

    var endAudioCalls: Int { lock.lock(); defer { lock.unlock() }; return _endAudioCalls }
    var cancelCalls: Int { lock.lock(); defer { lock.unlock() }; return _cancelCalls }

    func start(localeIdentifier: String, contextualStrings: [String]) -> AsyncStream<SpeechEvent> {
        let events = script
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func endAudio() { lock.lock(); _endAudioCalls += 1; lock.unlock() }
    func cancel() { lock.lock(); _cancelCalls += 1; lock.unlock() }
}

/// Records every intent and returns a fixed result.
@MainActor
final class RecordingExecutor: LocalExecuting {
    private(set) var executed: [LocalIntent] = []
    var result: LocalExecutionResult = .success(spoken: nil)

    func execute(_ intent: LocalIntent) async -> LocalExecutionResult {
        executed.append(intent)
        return result
    }
}

/// A backend that replays a fixed event script and records the calls made to it.
final class ScriptedBackend: AgentBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let preflightResult: AgentPreflightResult
    private let script: [AgentEvent]
    private var _submitted: [String] = []
    private var _responses: [(nonce: String, allow: Bool)] = []
    private var _cancelCalls = 0
    private var _emergencyStops = 0

    init(preflight: AgentPreflightResult = .ready(profile: "voice"), script: [AgentEvent] = []) {
        preflightResult = preflight
        self.script = script
    }

    var id: String { "scripted" }
    var submitted: [String] { lock.lock(); defer { lock.unlock() }; return _submitted }
    var responses: [(nonce: String, allow: Bool)] { lock.lock(); defer { lock.unlock() }; return _responses }
    var cancelCalls: Int { lock.lock(); defer { lock.unlock() }; return _cancelCalls }
    var emergencyStops: Int { lock.lock(); defer { lock.unlock() }; return _emergencyStops }

    func preflight() async -> AgentPreflightResult { preflightResult }

    func submit(_ utterance: String) -> AsyncStream<AgentEvent> {
        lock.lock()
        _submitted.append(utterance)
        lock.unlock()
        let events = script
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func respond(nonce: String, allow: Bool) async {
        lock.lock(); _responses.append((nonce, allow)); lock.unlock()
    }

    func cancelTurn() async { lock.lock(); _cancelCalls += 1; lock.unlock() }

    func emergencyStop() async -> EmergencyStopReport {
        lock.lock(); _emergencyStops += 1; lock.unlock()
        return EmergencyStopReport()
    }

    func shutdown() async {}
}

/// An in-memory `FileWriting` keyed by path.
final class InMemoryFileWriter: FileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: [String]] = [:]
    private var directories: Set<String> = []

    init() {}

    func ensureDirectory(_ url: URL) throws {
        lock.lock(); directories.insert(url.path); lock.unlock()
    }

    func appendLine(_ line: String, to url: URL) throws {
        lock.lock(); files[url.path, default: []].append(line); lock.unlock()
    }

    func readLines(from url: URL) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return files[url.path] ?? []
    }

    func restrictToOwner(_ url: URL) throws {}

    func fileSize(_ url: URL) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return (files[url.path] ?? []).reduce(0) { $0 + $1.utf8.count + 1 }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        files[destination.path] = files[source.path]
        files[source.path] = nil
    }
}

/// Records every cue.
@MainActor
final class RecordingCuePlayer: VoiceCuePlaying {
    private(set) var cues: [VoiceCue] = []
    func play(_ cue: VoiceCue) { cues.append(cue) }
}

/// Collects every element of a finite stream.
func collect<Element>(_ stream: AsyncStream<Element>) async -> [Element] {
    var items: [Element] = []
    for await item in stream { items.append(item) }
    return items
}
