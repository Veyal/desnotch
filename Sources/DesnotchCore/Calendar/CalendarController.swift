import AppKit
import Combine
import EventKit
import Foundation
import os

/// Publishes the next upcoming (non-all-day) calendar event within the lookahead window
/// for the pill's calendar glance row. Access is requested once when the feature is enabled;
/// denial (or an inability to prompt) is surfaced as a hint row, and a grant made later in
/// System Settings is picked up when the app next becomes active. Refreshes on a timer plus
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

    /// An EventKit-free snapshot of one event, so selection rules can be unit tested.
    struct Candidate: Equatable {
        let title: String?
        let start: Date
        let end: Date
        let isAllDay: Bool
        let isCanceled: Bool
        /// True when the current user is an attendee who declined.
        let isDeclinedByCurrentUser: Bool
        let joinURL: URL?
    }

    public enum AccessState {
        case undetermined
        case granted
        /// Denied, restricted, or the process couldn't prompt - surfaced as a hint row
        /// in the pill so the user knows why no events appear.
        case denied
    }

    @Published public private(set) var nextEvent: NextEvent? {
        didSet { lastImminent = Self.isImminent(nextEvent) }
    }
    @Published public private(set) var accessState: AccessState = .undetermined
    /// Bumped when a time-derived value (`isImminent`) flips with no new event: the clock
    /// crossing T-30min or the event's end changes nothing the store reports, so without
    /// this nobody would re-render the wing indicator.
    @Published public private(set) var clockRevision = 0

    private let store = EKEventStore()
    private let lookahead: TimeInterval = 24 * 3600
    private let refreshInterval: TimeInterval = 30
    private let logger = Logger(subsystem: "com.desnotch.app", category: "calendar")
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var settingsObserver: AnyCancellable?
    private var activityObserver: AnyCancellable?
    private var activationObserver: NSObjectProtocol?
    /// The raw `EKAuthorizationStatus` (3 = authorized); tests inject it.
    private let authorizationStatus: () -> Int
    private let settings: SettingsStore
    private let activity: PollingActivity
    /// The feature flag as last delivered by the settings publisher. `@Published` emits
    /// before it stores, so reading `settings.calendarEnabled` inside the sink sees the old
    /// value.
    private var isFeatureEnabled: Bool
    private var isSuspended = false
    private var lastImminent = false
    private var hasAccess = false
    private var accessRequested = false
    /// Bumped on every refresh and whenever the feature is turned off, so a slow
    /// off-main query can never overwrite a newer result (or resurrect a cleared one).
    private var refreshGeneration = 0

    /// `settings` defaults to `SettingsStore.shared`; tests inject an isolated store.
    public init(
        permissionRequestsEnabled: Bool = true,
        settings: SettingsStore? = nil,
        activity: PollingActivity? = nil,
        authorizationStatus: @escaping () -> Int = {
            EKEventStore.authorizationStatus(for: .event).rawValue
        }
    ) {
        let settings = settings ?? .shared
        self.settings = settings
        self.activity = activity ?? .shared
        self.authorizationStatus = authorizationStatus
        self.isFeatureEnabled = settings.calendarEnabled
        // Only prompt for calendar permission when the feature is actually enabled -
        // a permission dialog for a toggled-off feature is first-run noise. If the user
        // enables it later, the settings observer requests access at that moment.
        if permissionRequestsEnabled && settings.calendarEnabled {
            activateIfAuthorized()
        }
        settingsObserver = settings.$calendarEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.isFeatureEnabled = enabled
                if enabled && permissionRequestsEnabled {
                    self.activateIfAuthorized()
                    self.updateRefreshing()
                    self.refresh()
                } else {
                    self.refreshGeneration += 1
                    if self.nextEvent != nil { self.nextEvent = nil }
                    self.updateRefreshing()
                }
            }
        // Like the other loops, the refresh timer stops while nobody can see the result
        // (displays or system asleep, session resigned).
        activityObserver = self.activity.$isSuspended
            .removeDuplicates()
            .sink { [weak self] suspended in
                guard let self else { return }
                self.isSuspended = suspended
                self.updateRefreshing()
                if !suspended { self.refresh() }
            }
        // Access granted in System Settings after a denial: the one-shot request latch would
        // never run again, so re-read the status whenever the user comes back to the app.
        if permissionRequestsEnabled {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in self?.recheckAuthorization() }
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

    /// Reads the current authorization instead of prompting: authorized goes straight to
    /// refreshing, a settled denial shows the hint, and only an undetermined status asks.
    private func activateIfAuthorized() {
        guard isFeatureEnabled else { return }
        switch authorizationStatus() {
        case 3:
            grantAccess()
        case 1, 2, 4:
            hasAccess = false
            accessState = .denied
        default:
            requestAccess()
        }
    }

    /// App activation: pick up a grant the user made in System Settings after a denial.
    private func recheckAuthorization() {
        guard isFeatureEnabled, !hasAccess, authorizationStatus() == 3 else { return }
        grantAccess()
    }

    private func grantAccess() {
        hasAccess = true
        accessState = .granted
        updateRefreshing()
        refresh()
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
                self.updateRefreshing()
                self.refresh()
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    /// The refresh timer and store observer run only while access is granted, the feature is
    /// on and someone could see the result; every other state tears them down.
    private func updateRefreshing() {
        if hasAccess && isFeatureEnabled && !isSuspended {
            startRefreshing()
        } else {
            stopRefreshing()
        }
    }

    /// Internal so tests can assert the loop follows the setting and the sleep gate.
    var isRefreshing: Bool { timer != nil }

    private func stopRefreshing() {
        timer?.invalidate()
        timer = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    private func startRefreshing() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.noteClock()
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }
    }

    /// Publishes when the clock alone moved `isImminent` (see `clockRevision`).
    private func noteClock() {
        let imminent = Self.isImminent(nextEvent)
        guard imminent != lastImminent else { return }
        lastImminent = imminent
        clockRevision &+= 1
    }

    private func refresh() {
        guard hasAccess else { return }
        guard isFeatureEnabled else {
            refreshGeneration += 1
            if nextEvent != nil { nextEvent = nil }
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        // events(matching:) is a synchronous store query; EKEventStore is documented
        // thread-safe, so run it off the main actor - at 30s cadence a many-calendar
        // query on main was periodic jank right where the pill animates.
        let store = self.store
        let lookahead = self.lookahead
        Task.detached(priority: .utility) { [weak self] in
            let next = Self.queryNextEvent(store: store, lookahead: lookahead)
            await MainActor.run { [weak self] in
                guard let self, generation == self.refreshGeneration else { return }
                if self.nextEvent != next { self.nextEvent = next }
            }
        }
    }

    nonisolated private static func queryNextEvent(store: EKEventStore, lookahead: TimeInterval) -> NextEvent? {
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(lookahead), calendars: nil
        )
        let candidates = store.events(matching: predicate).map { event in
            Candidate(
                title: event.title,
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                isCanceled: event.status == .canceled,
                isDeclinedByCurrentUser: event.attendees?.contains {
                    $0.isCurrentUser && $0.participantStatus == .declined
                } ?? false,
                joinURL: meetingURL(explicit: event.url, location: event.location, notes: event.notes)
            )
        }
        return selectNextEvent(from: candidates, now: now)
    }

    /// The soonest non-all-day event that has not ended, skipping canceled events and
    /// events the current user declined (they are not meetings to show up to).
    nonisolated static func selectNextEvent(from candidates: [Candidate], now: Date) -> NextEvent? {
        candidates
            .filter { !$0.isAllDay && !$0.isCanceled && !$0.isDeclinedByCurrentUser }
            .sorted { $0.start < $1.start }
            .first { $0.end > now }
            .map { NextEvent(title: $0.title ?? "Event", start: $0.start, end: $0.end, joinURL: $0.joinURL) }
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
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
}
