import AVFoundation
import Foundation
import Speech

@MainActor
final class SystemVoicePermissions: VoicePermissionProviding {
    init() {}

    nonisolated static func state(forMicrophone status: AVAuthorizationStatus) -> VoicePermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unknown
        }
    }

    nonisolated static func state(forSpeech status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermissionState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorized:
            return .authorized
        @unknown default:
            return .unknown
        }
    }

    nonisolated static func hasUsageDescription(info: [String: Any]?, key: String) -> Bool {
        guard let value = info?[key] as? String else {
            return false
        }
        return !value.isEmpty
    }

    func status() -> VoicePermissionStatus {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        return VoicePermissionStatus(
            microphone: Self.state(forMicrophone: micStatus),
            speech: Self.state(forSpeech: speechStatus)
        )
    }

    func request() async -> VoicePermissionStatus {
        let info = Bundle.main.infoDictionary
        let currentStatus = status()

        if currentStatus.microphone == .notDetermined && Self.hasUsageDescription(info: info, key: "NSMicrophoneUsageDescription") {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    continuation.resume()
                }
            }
        }

        if currentStatus.speech == .notDetermined && Self.hasUsageDescription(info: info, key: "NSSpeechRecognitionUsageDescription") {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        }

        return status()
    }
}
