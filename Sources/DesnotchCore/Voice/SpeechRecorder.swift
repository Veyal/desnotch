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
    /// Invoked on the main queue when capture stops itself (e.g. duration cap).
    var onAutoStop: (() -> Void)? { get set }
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
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            // The completion handler can be delayed indefinitely while the
            // system consent sheet is queued behind another privacy prompt.
            // Request access to show the sheet, then observe TCC directly so a
            // successful click cannot leave DictationController stranded in
            // `.requestingPermission`.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            for _ in 0..<600 { // bounded at 60 seconds if the sheet is ignored
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return false
                }
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized:
                    return true
                case .denied, .restricted:
                    return false
                case .notDetermined:
                    continue
                @unknown default:
                    return false
                }
            }
            return false
        @unknown default:
            return false
        }
    }
}

/// Captures mono PCM into a temporary WAV, bounded by both duration and size.
public final class SpeechRecorder: SpeechRecording {
    public static let maxBytes = 20 * 1024 * 1024
    public static let maxDuration: TimeInterval = 5 * 60

    public var isRecording: Bool { withStateLock { recording } }
    public var onAutoStop: (() -> Void)?
    /// Created only after microphone access is granted. An engine initialized
    /// before the first TCC grant can retain a stale zero/bogus input format,
    /// and installing a tap with that format raises an Objective-C exception.
    private var engine: AVAudioEngine?
    private let permission: MicrophonePermissionProviding
    private let fileManager: FileManager
    private let stateLock = NSCondition()
    private var recording = false
    private var activeWrites = 0
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var startedAt: Date?
    private var stopWorkItem: DispatchWorkItem?
    private var terminalError: SpeechRecorderError?
    private var finishedURL: URL?
    private var writtenBytes = 0

    public init(engine: AVAudioEngine? = nil,
                permission: MicrophonePermissionProviding = SystemMicrophonePermission(),
                fileManager: FileManager = .default) {
        self.engine = engine; self.permission = permission; self.fileManager = fileManager
    }

    public func start() async throws {
        guard !isRecording else { throw SpeechRecorderError.alreadyRecording }
        guard await permission.requestPermission() else { throw SpeechRecorderError.microphoneDenied }
        guard !isRecording else { throw SpeechRecorderError.alreadyRecording }
        let engine = engine ?? AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // AVAudioInputNode receives audio from hardware on its output bus. Its
        // input bus legitimately reports zero channels on real devices, which
        // made every live recording fail with `.noInput`.
        let format = input.outputFormat(forBus: 0)
        // When the default input device is disconnected, AVAudioEngine exposes
        // the output device's format here (for example 2ch/44.1 kHz) even
        // though the input node has no renderable stream. Do not install a tap
        // in that state: AVAudioNode raises an Objective-C exception instead
        // of returning a Swift error.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            self.engine = nil
            throw SpeechRecorderError.noInput
        }
        let url = fileManager.temporaryDirectory.appendingPathComponent("desnotch-dictation-\(UUID().uuidString).wav")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            try? fileManager.removeItem(at: url)
            self.engine = nil
            throw SpeechRecorderError.captureFailed
        }
        withStateLock {
            outputURL = url
            audioFile = file
            startedAt = Date()
            terminalError = nil
            finishedURL = nil
            writtenBytes = 0
            activeWrites = 0
            recording = true
        }
        // The tap runs on the realtime render thread: no file stats or long
        // critical sections here. Bytes are tracked arithmetically; the exact
        // size limit is still enforced against the real file in `stop()`.
        // Passing nil lets AVAudioEngine retain the input node's native format.
        // Supplying a stale/non-matching format can raise an Objective-C
        // exception when an input device changes between permission and start.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            guard self.beginWrite() else { return }
            defer { self.endWrite() }
            do {
                try file.write(from: buffer)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finishCapture(reason: .captureFailed)
                }
                return
            }
            let total = self.withStateLock { () -> Int in
                let bytesPerFrame = max(1, Int(buffer.format.streamDescription.pointee.mBytesPerFrame))
                let channelMultiplier = buffer.format.isInterleaved ? 1 : max(1, Int(buffer.format.channelCount))
                self.writtenBytes += Int(buffer.frameLength) * bytesPerFrame * channelMultiplier
                return self.writtenBytes
            }
            if total >= Self.maxBytes {
                DispatchQueue.main.async { [weak self] in
                    self?.finishCapture(reason: .fileTooLarge)
                }
            }
        }
        do { try engine.start() } catch {
            withStateLock { recording = false }
            input.removeTap(onBus: 0)
            cleanupFile()
            // On macOS a missing/disconnected input often leaves the input
            // node reporting the output device's format until start(). The
            // failure then arrives as a low-level AVFAudio `canPerformIO`
            // error; surface the actionable recorder error instead of a
            // generic voice failure. Other start failures remain capture
            // failures, but never leave a half-started engine behind.
            let inputFormat = input.inputFormat(forBus: 0)
            if inputFormat.channelCount == 0 || inputFormat.sampleRate == 0 {
                throw SpeechRecorderError.noInput
            }
            throw SpeechRecorderError.captureFailed
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
        // Hitting the duration cap is a normal end of capture. Other terminal
        // reasons remain errors, but every self-stop notifies the owner so the UI
        // cannot remain stranded in `.recording`.
        let autoStopped = reason == .durationLimitReached
        let shouldNotifyOwner = reason != nil
        let shouldFinish = withStateLock {
            guard recording else { return false }
            recording = false
            terminalError = autoStopped ? nil : reason
            finishedURL = outputURL
            return true
        }
        guard shouldFinish else { return }
        stopWorkItem?.cancel()
        stopWorkItem = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        waitForWritesToFinish()
        engine = nil
        if shouldNotifyOwner {
            DispatchQueue.main.async { [weak self] in self?.onAutoStop?() }
        }
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
        engine = nil
        stopWorkItem?.cancel()
        stopWorkItem = nil
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private func beginWrite() -> Bool {
        withStateLock {
            guard recording else { return false }
            activeWrites += 1
            return true
        }
    }

    private func endWrite() {
        withStateLock {
            activeWrites -= 1
            if activeWrites == 0 { stateLock.broadcast() }
        }
    }

    private func waitForWritesToFinish() {
        stateLock.lock()
        while activeWrites > 0 { stateLock.wait() }
        audioFile = nil
        stateLock.unlock()
    }
    deinit { cancel() }
}
