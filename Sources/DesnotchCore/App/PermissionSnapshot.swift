import ApplicationServices
import AVFoundation
import EventKit
import Foundation
import Speech

/// A read-only view of the packaged process's current TCC authorization state.
/// Creating a snapshot never requests access or opens System Settings.
public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public enum AccessibilityState: String, Codable, Sendable {
        case trusted
        case untrusted
    }

    public enum AuthorizationState: String, Codable, Sendable {
        case notDetermined
        case restricted
        case denied
        case authorized
        case fullAccess
        case writeOnly
        case unknown
    }

    public let accessibility: AccessibilityState
    public let calendar: AuthorizationState
    public let reminders: AuthorizationState
    public let microphone: AuthorizationState
    public let speech: AuthorizationState

    public static func current() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: AXIsProcessTrusted() ? .trusted : .untrusted,
            calendar: calendarState(for: EKEventStore.authorizationStatus(for: .event)),
            reminders: calendarState(for: EKEventStore.authorizationStatus(for: .reminder)),
            microphone: microphoneState(for: AVCaptureDevice.authorizationStatus(for: .audio)),
            speech: speechState(for: SFSpeechRecognizer.authorizationStatus())
        )
    }

    static func calendarState(for status: EKAuthorizationStatus) -> AuthorizationState {
        // The macOS 13 `authorized` value became `fullAccess` on macOS 14;
        // both use raw value 3 and both grant the read access desnotch needs.
        switch status.rawValue {
        case 0: return .notDetermined
        case 1: return .restricted
        case 2: return .denied
        case 3: return .fullAccess
        case 4: return .writeOnly
        default: return .unknown
        }
    }

    static func microphoneState(for status: AVAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }

    static func speechState(for status: SFSpeechRecognizerAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .unknown
        }
    }
}
