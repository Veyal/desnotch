import AppKit
import Combine
import Foundation

/// Shared gate for background polling loops. Polling that nobody can see is pure
/// waste, so loops stop while the displays are asleep, the system is asleep, or this
/// user session is not the active one (fast user switching / login window), and they
/// stretch their cadence in Low Power Mode.
///
/// Loops observe `isSuspended` (like `ClipboardController` observes its setting) and
/// start/cancel themselves, which keeps them testable: a test builds an instance on
/// private `NotificationCenter`s and posts the same notification names.
///
/// Push-driven sources (the MediaRemote adapter stream) deliberately do not use this:
/// they cost nothing while idle.
@MainActor
public final class PollingActivity: ObservableObject {
    public static let shared = PollingActivity()

    /// Low Power Mode multiplies polling intervals by this factor.
    public static let lowPowerIntervalMultiplier = 3.0

    /// True while nobody could see the result of a poll.
    @Published public private(set) var isSuspended = false
    @Published public private(set) var isLowPowerMode = false

    private var displaysAsleep = false
    private var systemAsleep = false
    private var sessionInactive = false
    private let lowPowerModeProvider: () -> Bool
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    public convenience init() {
        self.init(
            workspaceCenter: NSWorkspace.shared.notificationCenter,
            processInfoCenter: .default,
            lowPowerModeProvider: { ProcessInfo.processInfo.isLowPowerModeEnabled }
        )
    }

    /// Internal injection point so tests can drive the gate without touching the system.
    init(
        workspaceCenter: NotificationCenter,
        processInfoCenter: NotificationCenter,
        lowPowerModeProvider: @escaping () -> Bool
    ) {
        self.lowPowerModeProvider = lowPowerModeProvider
        isLowPowerMode = lowPowerModeProvider()

        observe(workspaceCenter, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        observe(workspaceCenter, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        observe(workspaceCenter, NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        observe(workspaceCenter, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        observe(processInfoCenter, .NSProcessInfoPowerStateDidChange) { _ in }
    }

    /// `interval` stretched for Low Power Mode.
    public func scaled(_ interval: TimeInterval) -> TimeInterval {
        isLowPowerMode ? interval * Self.lowPowerIntervalMultiplier : interval
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        update: @escaping (PollingActivity) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.refresh()
            }
        }
        observers.append((center, token))
    }

    private func refresh() {
        let suspended = displaysAsleep || systemAsleep || sessionInactive
        if isSuspended != suspended { isSuspended = suspended }
        let lowPower = lowPowerModeProvider()
        if isLowPowerMode != lowPower { isLowPowerMode = lowPower }
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }
}
