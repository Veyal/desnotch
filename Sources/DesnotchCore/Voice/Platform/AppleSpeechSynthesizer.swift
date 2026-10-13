import AVFoundation
import Foundation

/// Spoken replies via AVSpeechSynthesizer.
/// Thread safety: pending continuations dictionary is guarded by an internal NSLock;
/// synthesizer operations run serialized on the main dispatch queue.
final class AppleSpeechSynthesizer: NSObject, GatedSpeechSynthesizing, AVSpeechSynthesizerDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: CheckedContinuation<Bool, Never>] = [:]
    private var synthesizer: AVSpeechSynthesizer?

    override init() {
        super.init()
    }

    private func register(
        _ utterance: AVSpeechUtterance,
        _ continuation: CheckedContinuation<Bool, Never>
    ) -> [CheckedContinuation<Bool, Never>] {
        lock.lock()
        let superseded = Array(pending.values)
        pending.removeAll()
        pending[ObjectIdentifier(utterance)] = continuation
        lock.unlock()
        return superseded
    }

    private func take(_ utterance: AVSpeechUtterance) -> CheckedContinuation<Bool, Never>? {
        lock.lock()
        let cont = pending.removeValue(forKey: ObjectIdentifier(utterance))
        lock.unlock()
        return cont
    }

    func speak(_ text: String, localeIdentifier: String) async -> Bool {
        await speak(text, localeIdentifier: localeIdentifier, shouldStart: { true })
    }

    /// `shouldStart` is asked on the main queue right before speaking; false returns false
    /// without speaking.
    func speak(
        _ text: String, localeIdentifier: String, shouldStart: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }
        let boundedText = String(trimmed.prefix(VoiceLimits.maxReplyCharacters))
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self, shouldStart() else {
                    continuation.resume(returning: false)
                    return
                }
                if self.synthesizer == nil {
                    let synth = AVSpeechSynthesizer()
                    synth.delegate = self
                    self.synthesizer = synth
                }
                guard let synth = self.synthesizer else {
                    continuation.resume(returning: false)
                    return
                }
                let utterance = AVSpeechUtterance(string: boundedText)
                utterance.voice = AVSpeechSynthesisVoice(language: localeIdentifier)
                let superseded = self.register(utterance, continuation)
                superseded.forEach { $0.resume(returning: false) }
                if !superseded.isEmpty {
                    synth.stopSpeaking(at: .immediate)
                }
                synth.speak(utterance)
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.synthesizer?.stopSpeaking(at: .immediate)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        take(utterance)?.resume(returning: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        take(utterance)?.resume(returning: false)
    }
}
