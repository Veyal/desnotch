import AVFoundation
import Foundation

public enum SpeechRecorderError: Error, Equatable {
    case microphoneDenied
    case alreadyRecording
    case notRecording
    case noInput
    case fileTooLarge
    case durationLimitReached
    case captureFailed
}

extension SpeechRecorderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access is required for voice actions."
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "No recording is in progress."
        case .noInput: return "No microphone input is available."
        case .fileTooLarge: return "The recording reached the 20 MiB limit."
        case .durationLimitReached: return "The recording reached the five-minute limit."
        case .captureFailed: return "Audio capture failed."
        }
    }
}

public protocol SpeechRecording: AnyObject {
    var isRecording: Bool { get }
    func start() async throws
    func stop() async throws -> URL
    func cancel()
}

public protocol MicrophonePermissionProviding {
    func requestPermission() async -> Bool
}

public struct SystemMicrophonePermission: MicrophonePermissionProviding {
    public init() {}
    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
    }
}

/// Captures mono PCM into a temporary WAV, bounded by both duration and size.
public final class SpeechRecorder: SpeechRecording {
    public static let maxBytes = 20 * 1024 * 1024
    public static let maxDuration: TimeInterval = 5 * 60

    public var isRecording: Bool { withStateLock { recording } }
    private let engine: AVAudioEngine
    private let permission: MicrophonePermissionProviding
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var recording = false
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var startedAt: Date?
    private var stopWorkItem: DispatchWorkItem?
    private var terminalError: SpeechRecorderError?
    private var finishedURL: URL?

    public init(engine: AVAudioEngine = AVAudioEngine(),
                permission: MicrophonePermissionProviding = SystemMicrophonePermission(),
                fileManager: FileManager = .default) {
        self.engine = engine; self.permission = permission; self.fileManager = fileManager
    }

    public func start() async throws {
        guard !isRecording else { throw SpeechRecorderError.alreadyRecording }
        guard await permission.requestPermission() else { throw SpeechRecorderError.microphoneDenied }
        guard !isRecording else { throw SpeechRecorderError.alreadyRecording }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw SpeechRecorderError.noInput }
        let url = fileManager.temporaryDirectory.appendingPathComponent("desnotch-dictation-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        withStateLock {
            outputURL = url
            audioFile = file
            startedAt = Date()
            terminalError = nil
            finishedURL = nil
            recording = true
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                let wrote = try self.withStateLock {
                    guard self.recording else { return false }
                    try file.write(from: buffer)
                    return true
                }
                guard wrote else { return }
                let size = (try? self.fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size >= Self.maxBytes {
                    DispatchQueue.main.async { [weak self] in
                        self?.finishCapture(reason: .fileTooLarge)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finishCapture(reason: .captureFailed)
                }
            }
        }
        do { try engine.start() } catch {
            withStateLock { recording = false }
            input.removeTap(onBus: 0)
            cleanupFile()
            throw error
        }
        let work = DispatchWorkItem { [weak self] in
            self?.finishCapture(reason: .durationLimitReached)
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration, execute: work)
    }

    public func stop() async throws -> URL {
        let pendingURL = withStateLock { outputURL ?? finishedURL }
        guard let url = pendingURL else { throw SpeechRecorderError.notRecording }
        if isRecording { finishCapture(reason: nil) }
        let captureError = withStateLock {
            let error = terminalError
            terminalError = nil
            return error
        }
        if let terminalError = captureError {
            cleanupFile()
            throw terminalError
        }
        if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue > Self.maxBytes {
            cleanupFile(); throw SpeechRecorderError.fileTooLarge
        }
        withStateLock {
            finishedURL = nil
            outputURL = nil
        }
        return url
    }

    public func cancel() { finishCapture(reason: nil); cleanupFile() }

    private func finishCapture(reason: SpeechRecorderError?) {
        let shouldFinish = withStateLock {
            guard recording else { return false }
            recording = false
            terminalError = reason
            finishedURL = outputURL
            audioFile = nil
            return true
        }
        guard shouldFinish else { return }
        stopWorkItem?.cancel()
        stopWorkItem = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
    private func cleanupFile() {
        let url = withStateLock {
            let url = outputURL ?? finishedURL
            recording = false
            outputURL = nil
            finishedURL = nil
            startedAt = nil
            terminalError = nil
            audioFile = nil
            return url
        }
        if let url { try? fileManager.removeItem(at: url) }
        stopWorkItem?.cancel()
        stopWorkItem = nil
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
    deinit { cancel() }
}
