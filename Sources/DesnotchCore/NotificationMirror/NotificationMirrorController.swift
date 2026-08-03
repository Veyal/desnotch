import AppKit
import Combine
import os

/// Owns the notification-mirror feature: permission lifecycle, the AX observer, the
/// per-app mute list, and the single most-recent banner the pill renders.
///
/// Privacy rules (load-bearing): banners live only in `latest` (memory), are dropped
/// after `latestLifetime`, and only the app name plus a hard-capped content line ever
/// reach the UI. Nothing here persists notification content anywhere. The feature is
/// OFF by default (`SettingsStore.notificationMirrorEnabled`), and enabling it
/// requires the user to also grant Accessibility - two explicit opt-ins.
@MainActor
public final class NotificationMirrorController: ObservableObject {
    public enum PermissionState: Equatable {
        /// Feature disabled in Settings; no observer, no permission checks.
        case off
        /// Feature enabled but Accessibility not granted - observer idle, Settings
        /// shows the grant/retry flow. Rechecked on a slow timer so flipping the
        /// toggle in System Settings lights the feature up without a relaunch.
        case needsPermission
        /// Observing Notification Center.
        case active
    }

    @Published public private(set) var latest: MirroredNotification?
    @Published public private(set) var permission: PermissionState = .off
    /// Monotonic arrival counter - the UI's animation trigger (a repeat notification
    /// from the same app with the same text still pulses).
    @Published public private(set) var arrivalCount = 0

    /// How long the most recent banner stays available to the pill before fading.
    static let latestLifetime: TimeInterval = 60
    /// Identical app+content within this window is the same banner re-reported
    /// (banner window plus the Notification Center list can both fire) - ignore it.
    static let duplicateWindow: TimeInterval = 2

    private let logger = Logger(subsystem: "com.desnotch.app", category: "NotificationMirror")
    private let presentation: NotchPillPresentation
    private let settings: SettingsStore
    private let observer = NotificationCenterObserver()
    private var expiryTimer: Timer?
    private var permissionTimer: Timer?
    private var cancellable: AnyCancellable?

    public init(presentation: NotchPillPresentation, settings: SettingsStore) {
        self.presentation = presentation
        self.settings = settings
        observer.onBanner = { [weak self] raw in
            self?.handleBanner(raw) ?? false
        }
        cancellable = settings.$notificationMirrorEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.applyEnabled(enabled)
            }
    }

    // MARK: - Permission flow

    /// Called from Settings' "Check again" button and the slow recheck timer.
    public func recheckPermission() {
        guard settings.notificationMirrorEnabled else { return }
        applyEnabled(true)
    }

    /// Triggers the system Accessibility-grant dialog (it has its own "Open System
    /// Settings" button); Settings also offers a direct open for the denied state.
    public func requestPermission() {
        NotificationCenterObserver.promptForTrust()
    }

    public static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func applyEnabled(_ enabled: Bool) {
        guard enabled else {
            observer.stop()
            permissionTimer?.invalidate()
            permissionTimer = nil
            expiryTimer?.invalidate()
            latest = nil
            permission = .off
            return
        }
        if NotificationCenterObserver.isTrusted {
            permissionTimer?.invalidate()
            permissionTimer = nil
            observer.start()
            permission = .active
        } else {
            permission = .needsPermission
            schedulePermissionRecheck()
        }
    }

    /// While enabled-but-denied, poll the trust flag every 5s so granting it in
    /// System Settings activates the feature without relaunching or re-toggling.
    private func schedulePermissionRecheck() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.permission == .needsPermission else { return }
                if NotificationCenterObserver.isTrusted {
                    self.applyEnabled(true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: - Banner handling

    /// Returns whether the system banner should now be closed: only ever true when
    /// the banner was actually mirrored into the pill AND the user asked for it. A
    /// muted app keeps its normal system banner - muting means "not in the notch",
    /// not "silently swallowed".
    @discardableResult
    private func handleBanner(_ raw: String) -> Bool {
        // Lowercased display names of everything running, so the parser can promote
        // the chunk that actually names an app (sender-first layouts, wrappers).
        let runningNames = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() }
        )
        guard let parsed = MirroredNotification.parse(
            rawDescription: raw, runningAppNames: runningNames
        ) else { return false }
        // Content-free diagnostics (counts and booleans only - NEVER banner text):
        // enough to tell which banner layout this macOS build produces when tuning
        // on real hardware. `log stream --predicate 'subsystem == "com.desnotch.app"'`.
        logger.debug(
            "Banner parsed: appMatchedRunning=\(runningNames.contains(parsed.appName.lowercased())), hasContent=\(parsed.content != nil)"
        )
        guard !isMuted(parsed.appName) else { return false }
        if let latest,
            latest.appName == parsed.appName,
            latest.content == parsed.content,
            parsed.receivedAt.timeIntervalSince(latest.receivedAt) < Self.duplicateWindow {
            // Same banner re-reported - already mirrored, so still ours to dismiss.
            return settings.dismissSystemBanners
        }
        latest = parsed
        arrivalCount += 1
        presentation.flashOpen(for: 4.0)
        scheduleExpiry()
        return settings.dismissSystemBanners
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: Self.latestLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in self?.latest = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: - Per-app mute

    public func isMuted(_ appName: String) -> Bool {
        settings.mutedNotificationApps.contains(appName.lowercased())
    }

    /// Mutes the latest banner's app and clears the row (menu action).
    public func muteLatestApp() {
        guard let latest else { return }
        settings.setNotificationApp(latest.appName, muted: true)
        self.latest = nil
    }

    // MARK: - Source app

    /// Activates the app whose banner is showing, matched by display name (the AX
    /// tree exposes no bundle identifier). Name collisions just activate the first
    /// match - benign for a convenience jump.
    public func activateSource() {
        guard let latest else { return }
        let running = NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(latest.appName) == .orderedSame
        }
        guard let running else { return }
        if #available(macOS 14.0, *) {
            running.activate()
        } else {
            running.activate(options: [])
        }
    }

    /// Icon for the latest banner's app (nil when it isn't running - the pill falls
    /// back to a bell symbol).
    public func sourceIcon(for appName: String) -> NSImage? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }?.icon
    }
}
