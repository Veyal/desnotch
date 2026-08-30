import AppKit
import Combine
import EventKit
import Foundation

/// The single reminder surfaced by the notch.  Reminder titles are bounded and
/// normalized before they cross this model boundary; no reminder data is persisted.
@MainActor
public final class RemindersController: ObservableObject {
    public struct NextReminder: Equatable, Identifiable {
        public let id: String
        public let title: String
        public let dueDate: Date
        public let isAllDay: Bool

        public init(id: String, title: String, dueDate: Date, isAllDay: Bool) {
            self.id = id
            self.title = title
            self.dueDate = dueDate
            self.isAllDay = isAllDay
        }
    }

    public enum AccessState: Equatable {
        case undetermined
        case granted
        case denied
    }

    /// A small, EventKit-free value used by selection tests and by callers that
    /// already have reminder snapshots.
    public struct Candidate: Equatable {
        public let id: String
        public let title: String
        public let dueDate: Date
        public let isAllDay: Bool
        public let isCompleted: Bool

        public init(id: String, title: String, dueDate: Date, isAllDay: Bool, isCompleted: Bool = false) {
            self.id = id
            self.title = title
            self.dueDate = dueDate
            self.isAllDay = isAllDay
            self.isCompleted = isCompleted
        }
    }

    @Published public private(set) var nextReminder: NextReminder?
    @Published public private(set) var accessState: AccessState = .undetermined

    private let store = EKEventStore()
    private let lookahead: TimeInterval = 7 * 24 * 3600
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var settingsObserver: AnyCancellable?
    private let permissionRequestsEnabled: Bool
    private var accessRequested = false
    private var hasAccess = false
    private var refreshGeneration = 0

    public init(permissionRequestsEnabled: Bool = true) {
        self.permissionRequestsEnabled = permissionRequestsEnabled
        settingsObserver = SettingsStore.shared.$remindersEnabled
            .removeDuplicates()
            // Initialization handles the persisted current value explicitly below;
            // observe only subsequent user changes here.
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.activateIfAuthorized()
                } else {
                    self.stopRefreshing()
                }
            }
        if SettingsStore.shared.remindersEnabled {
            activateIfAuthorized()
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in self?.activateIfAuthorized() }
        }
    }

    public var isUrgent: Bool {
        guard let nextReminder else { return false }
        return Self.isUrgent(nextReminder)
    }

    nonisolated public static func isUrgent(_ reminder: NextReminder, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if reminder.isAllDay {
            return calendar.startOfDay(for: reminder.dueDate) <= calendar.startOfDay(for: now)
        }
        return reminder.dueDate.timeIntervalSince(now) <= 30 * 60
    }

    /// Returns the most overdue reminder, otherwise the nearest due reminder in
    /// the next seven days. All-day reminders compare by local calendar day.
    nonisolated public static func selectNextReminder(
        from candidates: [Candidate],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Candidate? {
        let today = calendar.startOfDay(for: now)
        let limit = calendar.date(byAdding: .day, value: Int(lookaheadDays), to: now)
            ?? now.addingTimeInterval(lookaheadDays * 24 * 3600)
        let eligible = candidates.filter { candidate in
            guard !candidate.isCompleted else { return false }
            let due = candidate.isAllDay ? calendar.startOfDay(for: candidate.dueDate) : candidate.dueDate
            return due <= limit
        }
        return eligible.sorted { lhs, rhs in
            let left = lhs.isAllDay ? calendar.startOfDay(for: lhs.dueDate) : lhs.dueDate
            let right = rhs.isAllDay ? calendar.startOfDay(for: rhs.dueDate) : rhs.dueDate
            let leftOverdue = lhs.isAllDay ? left < today : left < now
            let rightOverdue = rhs.isAllDay ? right < today : right < now
            if leftOverdue != rightOverdue { return leftOverdue }
            if left != right { return left < right }
            return lhs.id < rhs.id
        }.first
    }

    nonisolated private static let lookaheadDays: Double = 7

    /// Removes line breaks/control characters and caps content for the
    /// permanently visible pill. Empty or whitespace-only titles get a safe name.
    nonisolated public static func sanitizeTitle(_ title: String, maxLength: Int = 120) -> String {
        let clean = title.unicodeScalars.map { scalar -> String in
            if scalar == "\n" || scalar == "\t" { return " " }
            return CharacterSet.controlCharacters.contains(scalar) ? "" : String(scalar)
        }
            .joined()
            .split(whereSeparator: { $0 == " " }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? "Reminder" : clean).prefix(maxLength))
    }

    nonisolated public static func dueLabel(_ date: Date, isAllDay: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: date)
        if dueDay < today || (!isAllDay && date < now) { return "Overdue" }
        if calendar.isDate(dueDay, inSameDayAs: today) {
            return isAllDay ? "Today" : "Today · \(date.formatted(date: .omitted, time: .shortened))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(dueDay, inSameDayAs: tomorrow) {
            return isAllDay ? "Tomorrow" : "Tomorrow · \(date.formatted(date: .omitted, time: .shortened))"
        }
        let day = calendar.component(.day, from: dueDay)
        let month = calendar.shortMonthSymbols[calendar.component(.month, from: dueDay) - 1]
        return isAllDay ? "\(month) \(day)" : "\(month) \(day) · \(date.formatted(date: .omitted, time: .shortened))"
    }

    nonisolated public static func dueLabel(_ reminder: NextReminder, now: Date = Date(), calendar: Calendar = .current) -> String {
        dueLabel(reminder.dueDate, isAllDay: reminder.isAllDay, now: now, calendar: calendar)
    }

    @discardableResult
    public func complete(_ identifier: String) -> Bool {
        guard hasAccess,
              SettingsStore.shared.remindersEnabled,
              let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder
        else { return false }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            if nextReminder?.id == identifier { nextReminder = nil }
            refresh()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func add(title: String, dueDate: Date?, isAllDay: Bool) -> Bool {
        guard hasAccess,
              SettingsStore.shared.remindersEnabled,
              let calendar = store.defaultCalendarForNewReminders()
        else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = Self.sanitizeTitle(title)
        if let dueDate {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
            if !isAllDay { components = Calendar.current.dateComponents(in: Calendar.current.timeZone, from: dueDate) }
            reminder.dueDateComponents = components
        }
        do { try store.save(reminder, commit: true); refresh(); return true }
        catch { return false }
    }

    private func activateIfAuthorized() {
        guard SettingsStore.shared.remindersEnabled else { return }
        switch EKEventStore.authorizationStatus(for: .reminder).rawValue {
        case 3:
            hasAccess = true
            accessState = .granted
            startRefreshing()
            refresh()
        case 1, 2, 4:
            hasAccess = false
            accessState = .denied
        default:
            accessState = .undetermined
            if permissionRequestsEnabled { requestAccess() }
        }
    }

    private func requestAccess() {
        guard SettingsStore.shared.remindersEnabled else { return }
        guard !accessRequested else { return }
        accessRequested = true
        let completion: (Bool, Error?) -> Void = { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.hasAccess = false
                    self.accessState = .denied
                    return
                }
                self.hasAccess = true
                self.accessState = .granted
                if SettingsStore.shared.remindersEnabled {
                    self.startRefreshing()
                    self.refresh()
                }
            }
        }
        if #available(macOS 14.0, *) { store.requestFullAccessToReminders(completion: completion) }
        else { store.requestAccess(to: .reminder, completion: completion) }
    }

    private func startRefreshing() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
    }

    private func stopRefreshing() {
        refreshGeneration += 1
        timer?.invalidate()
        timer = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
        if nextReminder != nil { nextReminder = nil }
    }

    private func refresh() {
        guard hasAccess, SettingsStore.shared.remindersEnabled else { return }
        guard EKEventStore.authorizationStatus(for: .reminder).rawValue == 3 else {
            hasAccess = false
            accessState = .denied
            stopRefreshing()
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let store = self.store
        let lookahead = self.lookahead
        Task.detached(priority: .utility) { [weak self] in
            let now = Date()
            let start = Calendar.current.date(byAdding: .year, value: -10, to: now) ?? now
            let end = Calendar.current.date(byAdding: .day, value: Int(Self.lookaheadDays), to: now)
                ?? now.addingTimeInterval(lookahead)
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: start,
                ending: end,
                calendars: nil
            )
            let reminders = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            let candidates = reminders.compactMap { reminder -> Candidate? in
                guard let components = reminder.dueDateComponents,
                      let due = Calendar.current.date(from: components), due >= start, due <= end else { return nil }
                return Candidate(id: reminder.calendarItemIdentifier, title: Self.sanitizeTitle(reminder.title ?? "Reminder"), dueDate: due, isAllDay: components.hour == nil, isCompleted: reminder.isCompleted)
            }
            let selected = Self.selectNextReminder(from: candidates, now: now)
            await MainActor.run { [weak self] in
                guard let self, generation == self.refreshGeneration else { return }
                self.nextReminder = selected.map { NextReminder(id: $0.id, title: $0.title, dueDate: $0.dueDate, isAllDay: $0.isAllDay) }
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}
