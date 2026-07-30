import AppKit
import UserNotifications

/// Fires when an agent session newly flips to "needs your turn". Packaged `.app`: a local
/// user notification (with the standard one-time permission prompt). Bare `swift run`
/// binary: `UNUserNotificationCenter` requires a bundle identity and would crash, so it
/// falls back to a short sound. Toggleable from the status-bar menu; enabled by default.
public final class AgentAttentionNotifier {
    public static let shared = AgentAttentionNotifier()
    public static let defaultsKey = "notifyAgentNeedsYou"

    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    private var authRequested = false
    private var canUseUserNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    public func notifyNeedsYou(_ label: String) {
        notify(title: "Agent needs you", body: label)
    }

    public func notify(title: String, body: String) {
        guard isEnabled else { return }
        guard canUseUserNotifications else {
            NSSound(named: "Glass")?.play()
            return
        }
        requestAuthIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestAuthIfNeeded() {
        guard !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
