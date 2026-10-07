import AppKit

/// Wording for the VoiceOver announcements the pill makes. Pure so the text is unit-testable.
/// The pill's panel is non-activating, never key and hover-driven, so keyboard focus cannot reach it
/// (VoiceOver reaches it only through the cursor while it is pinned open); these announcements are
/// how a VoiceOver user learns that something landed there.
/// Banner and reminder *content* is deliberately never announced (the pill is screen-shared
/// and Privacy mode must keep working), only that an event happened.
public enum PillAnnouncements {
    public static func volume(_ level: Float) -> String {
        let percent = Int((min(max(level, 0), 1) * 100).rounded())
        return "Volume \(percent) percent"
    }

    public static func power(isPluggedIn: Bool, percent: Int) -> String {
        let clamped = min(max(percent, 0), 100)
        return isPluggedIn
            ? "Plugged in, \(clamped) percent"
            : "On battery, \(clamped) percent"
    }

    public static func pinned(_ isPinned: Bool) -> String {
        isPinned ? "Notch held open" : "Notch released"
    }

    public static let trayAdded = "Added to tray"
    public static let reminderCompleted = "Reminder completed"
    public static let reminderAdded = "Reminder added"
    public static let reminderFailed = "Couldn't update the reminder"
    public static let timerStarted = "Focus timer started"
    public static let timerCompleted = "Focus timer complete"
}

/// Posts a VoiceOver announcement. A no-op in practice when no assistive technology is
/// listening, so callers need not check whether VoiceOver is running.
@MainActor
public enum AccessibilityAnnouncer {
    public static func announce(
        _ message: String,
        priority: NSAccessibilityPriorityLevel = .medium
    ) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }
}
