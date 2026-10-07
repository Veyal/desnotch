import Foundation

/// Wording for the status-menu mirrors of pill glances (process warnings, battery), kept pure
/// so it is testable. The menu is the keyboard/VoiceOver route to what the hover-driven pill
/// shows, so the text carries the same facts as the pill row.
public enum StatusMenuText {
    public static func battery(_ state: BatteryController.BatteryState) -> String {
        let percent = min(max(state.percent, 0), 100)
        switch state.powerStatus {
        case .charging: return "Battery \(percent)% - charging"
        case .pluggedIn: return "Battery \(percent)% - plugged in"
        case .onBattery: return "Battery \(percent)% - on battery"
        }
    }

    public static func hotProcess(_ process: HotProcess, now: Date = Date()) -> String {
        let name = String(process.name.prefix(40))
        return "\(name) - \(Int(process.cpu))% CPU for \(duration(since: process.since, now: now))"
    }

    /// "under a minute", "5 min", "2 h".
    static func duration(since: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes == 0 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h"
    }
}
