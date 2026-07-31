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
