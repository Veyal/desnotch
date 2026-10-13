import AVFoundation
import Foundation

enum VoicePlaybackOutcome: Equatable, Sendable {
    case finished
    /// `stop()` ended it.
    case stopped
    /// The data could not be decoded or played.
    case failed
}

/// Plays one in-memory audio clip. A seam so the synthesizer is testable without audio output.
protocol VoiceAudioPlaying: Sendable {
    func play(_ data: Data) async -> VoicePlaybackOutcome
    func stop()
}

/// Spoken replies through the opt-in provider: `POST {base}/audio/speech`, the returned audio
/// played from memory. Any provider failure (not set up, network, HTTP error, undecodable or
/// oversized audio) falls back to the macOS voice, so a reply is still spoken; Stop/Cancel
/// cancels the request and the playback and does not fall back. `speak` returns like the macOS
/// synthesizer: true when the reply finished, false when it was stopped or could not play.
/// Thread safety: the generation and the pending request are guarded by `lock`.
final class OpenAISpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let config: VoiceAIConfigBox
    private let keys: VoiceAIKeyStoring
    private let session: URLSession
    private let player: VoiceAudioPlaying
    private let fallback: SpeechSynthesizing
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var request: Task<VoiceAIResponse, Never>?

    init(
        config: VoiceAIConfigBox,
        keys: VoiceAIKeyStoring,
        session: URLSession,
        player: VoiceAudioPlaying,
        fallback: SpeechSynthesizing
    ) {
        self.config = config
        self.keys = keys
        self.session = session
        self.player = player
        self.fallback = fallback
    }

    func speak(_ text: String, localeIdentifier: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let bounded = String(trimmed.prefix(VoiceLimits.maxReplyCharacters))
        let snapshot = config.current()
        let ticket = begin()
        guard case .success(let ready) = VoiceAIReadiness.resolve(base: snapshot.baseURL, keys: keys) else {
            return await speakWithFallback(bounded, localeIdentifier: localeIdentifier, ticket: ticket)
        }
        let urlRequest = OpenAIAudioWire.speech(
            base: ready.base, key: ready.key, model: snapshot.ttsModel, voice: snapshot.ttsVoice, input: bounded
        )
        let session = self.session
        let task = Task {
            await VoiceAIHTTP.send(urlRequest, session: session, maxBytes: VoiceAILimits.maxSpeechBytes)
        }
        guard attach(task, ticket: ticket) else { return false }
        let response = await task.value
        guard isCurrent(ticket) else { return false }
        guard case .ok(let audio) = response, !audio.isEmpty else {
            if response == .cancelled { return false }
            return await speakWithFallback(bounded, localeIdentifier: localeIdentifier, ticket: ticket)
        }
        switch await player.play(audio) {
        case .finished:
            return true
        case .stopped:
            return false
        case .failed:
            return await speakWithFallback(bounded, localeIdentifier: localeIdentifier, ticket: ticket)
        }
    }

    func stop() {
        let pending = invalidate()
        pending?.cancel()
        player.stop()
        fallback.stop()
    }

    private func speakWithFallback(_ text: String, localeIdentifier: String, ticket: UInt64) async -> Bool {
        guard isCurrent(ticket) else { return false }
        return await fallback.speak(text, localeIdentifier: localeIdentifier)
    }

    // MARK: - Generation (every access under `lock`, in synchronous helpers)

    private func begin() -> UInt64 {
        lock.lock()
        generation &+= 1
        let ticket = generation
        let previous = request
        request = nil
        lock.unlock()
        previous?.cancel()
        return ticket
    }

    private func attach(_ task: Task<VoiceAIResponse, Never>, ticket: UInt64) -> Bool {
        lock.lock()
        let current = generation == ticket
        if current { request = task }
        lock.unlock()
        if !current { task.cancel() }
        return current
    }

    private func isCurrent(_ ticket: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == ticket
    }

    private func invalidate() -> Task<VoiceAIResponse, Never>? {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        let pending = request
        request = nil
        return pending
    }
}

/// `AVAudioPlayer(data:)` on the main queue: the reply audio is never written to a file.
/// Thread safety: the current player and its continuation are guarded by `lock`.
final class AVAudioDataPlayer: NSObject, VoiceAudioPlaying, AVAudioPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<VoicePlaybackOutcome, Never>?

    func play(_ data: Data) async -> VoicePlaybackOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .failed)
                    return
                }
                self.finish(.stopped)
                guard let player = try? AVAudioPlayer(data: data) else {
                    continuation.resume(returning: .failed)
                    return
                }
                player.delegate = self
                self.install(player, continuation)
                if !player.play() {
                    self.finish(.failed)
                }
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.finish(.stopped)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(flag ? .finished : .failed, only: player)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(.failed, only: player)
    }

    private func install(_ player: AVAudioPlayer, _ continuation: CheckedContinuation<VoicePlaybackOutcome, Never>) {
        lock.lock()
        self.player = player
        self.continuation = continuation
        lock.unlock()
    }

    /// Resumes the current playback once. With `only`, a late callback from an older player
    /// is ignored.
    private func finish(_ outcome: VoicePlaybackOutcome, only: AVAudioPlayer? = nil) {
        lock.lock()
        if let only, only !== player {
            lock.unlock()
            return
        }
        let current = player
        let pending = continuation
        player = nil
        continuation = nil
        lock.unlock()
        if outcome == .stopped { current?.stop() }
        pending?.resume(returning: outcome)
    }
}
