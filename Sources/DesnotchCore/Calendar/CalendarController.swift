import EventKit
import Foundation
import os

/// Publishes the next upcoming (non-all-day) calendar event within the lookahead window
/// for the pill's calendar glance row. Access is requested once at init; if the user
/// denies it (or the process can't prompt), `nextEvent` simply stays nil and the row
/// never appears. Refreshes on a timer plus `EKEventStoreChanged`.
@MainActor
public final class CalendarController: ObservableObject {
    public struct NextEvent: Equatable {
        public let title: String
        public let start: Date
        public let end: Date

        public init(title: String, start: Date, end: Date) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    public enum AccessState {
        case undetermined
        case granted
        /// Denied, restricted, or the process couldn't prompt - surfaced as a hint row
        /// in the pill so the user knows why no events appear.
        case denied
    }

    @Published public private(set) var nextEvent: NextEvent?
    @Published public private(set) var accessState: AccessState = .undetermined

    private let store = EKEventStore()
    private let lookahead: TimeInterval = 24 * 3600
    private let refreshInterval: TimeInterval = 30
    private let logger = Logger(subsystem: "com.desnotch.app", category: "calendar")
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var hasAccess = false

    public init() {
        requestAccess()
    }

    /// Starting within 30 minutes, or already ongoing - enough to keep the pill visible
    /// on its own (a plain "there is a meeting later today" is not a live activity).
    public var isImminent: Bool {
        Self.isImminent(nextEvent)
    }

    public static func isImminent(_ event: NextEvent?) -> Bool {
        guard let event else { return false }
        return event.start.timeIntervalSinceNow < 30 * 60 && event.end.timeIntervalSinceNow > 0
    }

    private func requestAccess() {
        let handler: (Bool, Error?) -> Void = { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.logger.error("calendar access request failed: \(error.localizedDescription)")
                }
                guard granted else {
                    self.logger.notice("calendar access not granted")
                    self.accessState = .denied
                    return
                }
                self.logger.info("calendar access granted; \(self.store.calendars(for: .event).count) calendars")
                self.accessState = .granted
                self.hasAccess = true
                self.startRefreshing()
                self.refresh()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    private func startRefreshing() {
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard hasAccess else { return }
        guard SettingsStore.shared.calendarEnabled else {
            if nextEvent != nil { nextEvent = nil }
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(lookahead), calendars: nil
        )
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first { $0.endDate > now }
        nextEvent = next.map {
            NextEvent(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate)
        }
    }

    deinit {
        timer?.invalidate()
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }
}
