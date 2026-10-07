import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp`, shared by the status menu and the Settings pane so
/// both agree on what "on" means. macOS owns this state (it is not stored in `SettingsStore`).
@MainActor
public enum LaunchAtLogin {
    public enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but macOS needs the user to allow desnotch under
        /// System Settings > General > Login Items before it will launch.
        case requiresApproval
        /// The service could not be found (for example a bare `swift run` binary).
        case unavailable

        /// True when a login item exists in any form, so the next toggle should remove it.
        public var isRegistered: Bool { self == .enabled || self == .requiresApproval }

        /// One line for the UI when the state needs explaining; nil when nothing needs saying.
        public var explanation: String? {
            switch self {
            case .requiresApproval:
                return "Allow desnotch in System Settings > General > Login Items to finish enabling this."
            case .unavailable:
                return "Launch at login needs the packaged desnotch.app; it is unavailable in this build."
            case .enabled, .disabled:
                return nil
            }
        }
    }

    nonisolated static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    public static var state: State {
        state(for: SMAppService.mainApp.status)
    }

    /// Registers or unregisters the login item and returns the resulting state. Throws the
    /// underlying `SMAppService` error (common for ad-hoc-signed builds); callers treat that as
    /// non-fatal.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) throws -> State {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        return state
    }

    /// Flips the login item (removing it when registered in any form) and returns the new state.
    @discardableResult
    public static func toggle() throws -> State {
        try setEnabled(!state.isRegistered)
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
