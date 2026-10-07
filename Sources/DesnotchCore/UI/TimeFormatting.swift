import Foundation

/// Compact clock-style durations for the pill ("3:05", "1:07:45"). Kept as a standalone
/// helper so the formatting rules are unit-testable.
enum TimeFormatting {
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension TimeFormatting {
    /// Wing-sized remaining time: minutes rounded up ("24m") while a minute or more is left,
    /// seconds under a minute ("45s"), hours and minutes past an hour ("1h05"). Never a
    /// clock with seconds, which does not fit a 44pt wing. The exact time stays in the
    /// expanded row and the accessibility label.
    static func compact(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        if total < 60 { return "\(total)s" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }
}
