import Foundation

/// Local-day count of Hermes turns, stored outside `SettingsStore` so it is never exported.
/// A missing, corrupt, or negative count is zero, so `remaining` stays inside `0...limit`.
struct DailyTurnCounter {
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let limit: Int

    private static let dayKey = "voice.hermesTurns.day"
    private static let countKey = "voice.hermesTurns.count"

    init(defaults: UserDefaults, calendar: Calendar = .current, limit: Int = VoiceLimits.hermesTurnsPerDay) {
        self.defaults = defaults
        self.calendar = calendar
        // AMBIGUITY: a negative limit is not specified; treat it as zero so remaining cannot go negative.
        self.limit = max(0, limit)
    }

    func remaining(now: Date) -> Int {
        max(0, limit - storedCount(now: now))
    }

    mutating func increment(now: Date) {
        let day = dayString(from: now)
        let count = storedCount(now: now) + 1
        defaults.set(day, forKey: Self.dayKey)
        defaults.set(count, forKey: Self.countKey)
    }

    private func storedCount(now: Date) -> Int {
        guard defaults.string(forKey: Self.dayKey) == dayString(from: now) else { return 0 }
        guard let object = defaults.object(forKey: Self.countKey) else { return 0 }
        // UserDefaults bridges integers as NSNumber, which casts to Int. Anything else is corrupt.
        guard let value = object as? Int else { return 0 }
        return max(0, value)
    }

    private func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
