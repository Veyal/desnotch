import Combine
import EventKit
import Foundation
import os

/// Publishes the next upcoming (non-all-day) calendar event within the lookahead window
/// for the pill's calendar glance row. Access is requested once when the feature is enabled;
/// denial (or an inability to prompt) is surfaced as a hint row. Refreshes on a timer plus
/// `EKEventStoreChanged` after access is granted.
@MainActor
public final class CalendarController: ObservableObject {
    public struct NextEvent: Equatable {
        public let title: String
        public let start: Date
        public let end: Date
        /// A recognized web-conferencing URL, if the event contains one. The URL is
        /// used only as an open target and is never rendered or persisted.
        public let joinURL: URL?

        public init(title: String, start: Date, end: Date, joinURL: URL? = nil) {
            self.title = title
            self.start = start
            self.end = end
            self.joinURL = joinURL
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
    private var settingsObserver: AnyCancellable?
    private var hasAccess = false
    private var accessRequested = false

    public init(permissionRequestsEnabled: Bool = true) {
        // Only prompt for calendar permission when the feature is actually enabled -
        // a permission dialog for a toggled-off feature is first-run noise. If the user
        // enables it later, the settings observer requests access at that moment.
        if permissionRequestsEnabled && SettingsStore.shared.calendarEnabled {
            requestAccess()
        }
        settingsObserver = SettingsStore.shared.$calendarEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled && permissionRequestsEnabled {
                    self.requestAccess()
                    self.refresh()
                } else if self.nextEvent != nil {
                    self.nextEvent = nil
                }
            }
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
        guard !accessRequested else { return }
        accessRequested = true
        let handler: (Bool, Error?) -> Void = { [weak self] granted, error in
            Task { @MainActor [weak self] in
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
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        guard hasAccess else { return }
        guard SettingsStore.shared.calendarEnabled else {
            if nextEvent != nil { nextEvent = nil }
            return
        }
        // events(matching:) is a synchronous store query; EKEventStore is documented
        // thread-safe, so run it off the main actor - at 30s cadence a many-calendar
        // query on main was periodic jank right where the pill animates.
        let store = self.store
        let lookahead = self.lookahead
        Task.detached(priority: .utility) { [weak self] in
            let next = Self.queryNextEvent(store: store, lookahead: lookahead)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.nextEvent != next { self.nextEvent = next }
            }
        }
    }

    nonisolated private static func queryNextEvent(store: EKEventStore, lookahead: TimeInterval) -> NextEvent? {
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(lookahead), calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first { $0.endDate > now }
            .map {
                NextEvent(
                    title: $0.title ?? "Event",
                    start: $0.startDate,
                    end: $0.endDate,
                    joinURL: meetingURL(explicit: $0.url, location: $0.location, notes: $0.notes)
                )
            }
    }

    /// Finds a known web-conferencing link without exposing arbitrary URLs as a
    /// misleading "Join" action. Notes/location are bounded before link detection and
    /// discarded immediately; only the selected URL reaches `NextEvent`.
    nonisolated static func meetingURL(
        explicit: URL?,
        location: String?,
        notes: String?
    ) -> URL? {
        var candidates: [URL] = []
        if let explicit { candidates.append(explicit) }

        for text in [location, notes].compactMap({ $0 }).map({ String($0.prefix(4_096)) }) {
            guard let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
            ) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            candidates.append(contentsOf: detector.matches(in: text, range: range).compactMap(\.url))
        }

        return candidates.first(where: isRecognizedMeetingURL)
    }

    nonisolated private static func isRecognizedMeetingURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else { return false }

        let providers = [
            "zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com",
            "webex.com", "chime.aws", "whereby.com", "around.co", "bluejeans.com",
            "meet.jit.si", "gotomeeting.com", "goto.com", "facetime.apple.com"
        ]
        return providers.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    deinit {
        timer?.invalidate()
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }
}
