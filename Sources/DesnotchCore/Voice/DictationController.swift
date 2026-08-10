import Combine
import Foundation

public enum DictationMode: String, Equatable {
    case dictate
    case talkToAgent
}

public enum DictationState: Equatable {
    case idle
    case requestingPermission(DictationMode)
    case recording(DictationMode)
    case uploading(DictationMode)
    case success(DictationMode, String)
    case error(DictationMode?, String)
}

public enum DictationError: LocalizedError {
    case pasteUnavailable
    case emptyTranscript
    case transcriptTooLong

    public var errorDescription: String? {
        switch self {
        case .pasteUnavailable:
            return "Accessibility access is required to paste into the focused app."
        case .emptyTranscript:
            return "No speech was detected."
        case .transcriptTooLong:
            return "The transcription is too long to safely use."
        }
    }
}

/// Coordinates one push-to-talk operation. Audio and full transcripts remain
/// transient: only a short, bounded result is published for the on-screen status.
@MainActor
public final class DictationController: ObservableObject {
    public static let displayedTranscriptMax = 512

    @Published public private(set) var state: DictationState = .idle
    public var onTranscript: ((DictationMode, String) -> Void)?

    private let recorder: SpeechRecording
    private let transcriberProvider: @MainActor () -> SpeechTranscribing
    private let paster: AccessibilityPasting
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(
        recorder: SpeechRecording,
        transcriber: SpeechTranscribing,
        paster: AccessibilityPasting
    ) {
        self.recorder = recorder
        self.transcriberProvider = { transcriber }
        self.paster = paster
        wireAutoStop()
    }

    public init(
        recorder: SpeechRecording,
        transcriberProvider: @escaping @MainActor () -> SpeechTranscribing,
        paster: AccessibilityPasting
    ) {
        self.recorder = recorder
        self.transcriberProvider = transcriberProvider
        self.paster = paster
        wireAutoStop()
    }

    /// The recorder stops itself at the duration cap; transcribe what was captured
    /// instead of leaving the UI stuck in `.recording` and losing the audio.
    private func wireAutoStop() {
        recorder.onAutoStop = { [weak self] in
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    public var mode: DictationMode? {
        switch state {
        case .requestingPermission(let mode), .recording(let mode), .uploading(let mode),
             .success(let mode, _):
            return mode
        case .error(let mode, _):
            return mode
        case .idle:
            return nil
        }
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public func start() { start(mode: .dictate) }

    public func start(mode: DictationMode) {
        guard task == nil, !recorder.isRecording else { return }
        generation += 1
        let gen = generation
        state = .requestingPermission(mode)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start()
                try Task.checkCancellation()
                guard generation == gen else { return }
                state = .recording(mode)
                task = nil
                // Capture can fail terminally before this hop lands, while state
                // was still .requestingPermission and the auto-stop no-oped.
                if !recorder.isRecording { stop() }
            } catch is CancellationError {
                recorder.cancel()
                guard generation == gen else { return }
                state = .idle
                task = nil
            } catch {
                fail(error, mode: mode, generation: gen)
            }
        }
    }

    public func stop() {
        guard case .recording(let mode) = state else { return }
        let gen = generation
        state = .uploading(mode)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await recorder.stop()
                defer { try? FileManager.default.removeItem(at: url) }
                let text = try await transcriberProvider().transcribe(fileURL: url)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard generation == gen else { return }
                guard !text.isEmpty else { throw DictationError.emptyTranscript }
                guard text.utf8.count <= SpeechTranscriptionClient.maxTranscriptBytes else {
                    throw DictationError.transcriptTooLong
                }

                switch mode {
                case .dictate:
                    guard paster.paste(text) else { throw DictationError.pasteUnavailable }
                case .talkToAgent:
                    onTranscript?(mode, text)
                }
                state = .success(mode, Self.displayed(text))
                task = nil
            } catch is CancellationError {
                guard generation == gen else { return }
                state = .idle
                task = nil
            } catch {
                fail(error, mode: mode, generation: gen)
            }
        }
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        recorder.cancel()
        state = .idle
    }

    public func clearResult() {
        switch state {
        case .success, .error: state = .idle
        default: break
        }
    }

    public func requestAccessibilityPermission() -> Bool { paster.requestTrust() }
    public var hasAccessibilityPermission: Bool { paster.isTrusted }

    private func fail(_ error: Error, mode: DictationMode?, generation gen: Int) {
        recorder.cancel()
        guard generation == gen else { return }
        task = nil
        let message = (error as? LocalizedError)?.errorDescription ?? "The voice action failed."
        state = .error(mode, message)
    }

    private static func displayed(_ text: String) -> String {
        String(text.prefix(displayedTranscriptMax))
    }
}

public protocol SpeechTranscribing {
    func transcribe(fileURL: URL) async throws -> String
}

extension SpeechTranscriptionClient: SpeechTranscribing {}
