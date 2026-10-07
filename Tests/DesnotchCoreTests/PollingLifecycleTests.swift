import AppKit
import XCTest
@testable import DesnotchCore

/// The three polling loops (media use, agent scan, process monitor) follow their Settings
/// flag and the shared sleep/session gate instead of polling a flag every tick.
final class PollingLifecycleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspace: NotificationCenter!

    override func setUp() {
        super.setUp()
        suiteName = "desnotch.tests.polling.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        workspace = NotificationCenter()
    }

    @MainActor
    private func makeActivity() -> PollingActivity {
        PollingActivity(
            workspaceCenter: workspace,
            processInfoCenter: NotificationCenter(),
            lowPowerModeProvider: { false }
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func settle() async {
        await drainMainOperationQueue()
    }

    /// Polls a condition for up to ~2s; the loops run on their own tasks.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Media use

    @MainActor
    func testMediaUseFollowsSettingAndSleepGate() async {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.micCameraIndicatorEnabled = false
        let monitor = MediaUseMonitor(
            settings: settings, activity: activity, pollInterval: 0.05, probe: { (mic: true, camera: false) }
        )
        XCTAssertFalse(monitor.isPolling)
        XCTAssertFalse(monitor.micInUse)

        settings.micCameraIndicatorEnabled = true
        XCTAssertTrue(monitor.isPolling)
        await waitUntil { monitor.micInUse }
        XCTAssertTrue(monitor.micInUse)
        XCTAssertFalse(monitor.cameraInUse)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle()
        XCTAssertFalse(monitor.isPolling)

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        XCTAssertTrue(monitor.isPolling)

        settings.micCameraIndicatorEnabled = false
        XCTAssertFalse(monitor.isPolling)
        XCTAssertFalse(monitor.micInUse, "disabling clears the indicator")
    }

    /// With a push source the 5s poll loop is not started at all: the monitor probes once on
    /// start and then only when the source reports a change.
    @MainActor
    func testMediaUseListensInsteadOfPollingWhenTheSourceRegisters() async {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.micCameraIndicatorEnabled = false
        let source = FakeMediaUseSource()
        let reading = LockedReading(mic: true, camera: false)
        let monitor = MediaUseMonitor(
            settings: settings, activity: activity, pollInterval: 0.05, changeSource: source,
            probe: { reading.value }
        )
        XCTAssertFalse(source.isStarted)

        settings.micCameraIndicatorEnabled = true
        XCTAssertTrue(source.isStarted)
        XCTAssertTrue(monitor.isListeningForChanges)
        XCTAssertFalse(monitor.isPolling, "no timer while listeners are registered")
        await waitUntil { monitor.micInUse }
        XCTAssertTrue(monitor.micInUse, "initial reading on start")

        // No callback, no probe: a changed device state is not seen until the OS says so.
        reading.value = (mic: false, camera: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(monitor.micInUse)
        XCTAssertFalse(monitor.cameraInUse)

        source.fire()
        await waitUntil { monitor.cameraInUse }
        XCTAssertFalse(monitor.micInUse)
        XCTAssertTrue(monitor.cameraInUse)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle()
        XCTAssertFalse(source.isStarted, "listeners are dropped while nobody can see the result")
        XCTAssertFalse(monitor.isListeningForChanges)

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        XCTAssertTrue(source.isStarted)

        settings.micCameraIndicatorEnabled = false
        XCTAssertFalse(source.isStarted)
        XCTAssertFalse(monitor.cameraInUse)
    }

    @MainActor
    func testMediaUsePollsWhenListenersCannotRegisterOrFailLater() async {
        let settings = SettingsStore(defaults: defaults)
        settings.micCameraIndicatorEnabled = true
        let refusing = FakeMediaUseSource(accepts: false)
        let monitor = MediaUseMonitor(
            settings: settings, activity: makeActivity(), pollInterval: 0.05, changeSource: refusing,
            probe: { (mic: true, camera: false) }
        )
        XCTAssertTrue(monitor.isPolling, "registration failure keeps the poll fallback")
        XCTAssertFalse(monitor.isListeningForChanges)
        await waitUntil { monitor.micInUse }
        XCTAssertTrue(monitor.micInUse)

        let later = FakeMediaUseSource()
        let second = MediaUseMonitor(
            settings: settings, activity: makeActivity(), pollInterval: 0.05, changeSource: later,
            probe: { (mic: false, camera: false) }
        )
        XCTAssertFalse(second.isPolling)
        later.fail()
        await waitUntil { second.isPolling }
        XCTAssertTrue(second.isPolling, "a hot-plug registration failure falls back to polling")
        XCTAssertFalse(second.isListeningForChanges)
    }

    func testHardwareSourceStartsAndStopsCleanly() {
        let source = HardwareMediaUseSource()
        _ = source.start(onChange: {}, onFailure: {})
        source.stop()
        source.stop()
    }

    // MARK: Agent activity

    @MainActor
    func testAgentActivityFollowsSettingAndSleepGate() async {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.agentActivityEnabled = false
        let scans = ScanCounter()
        let controller = AgentActivityController(
            presentation: NotchPillPresentation(),
            settings: settings,
            activity: activity,
            scanInterval: 0.05,
            scan: { _, _ in scans.increment(); return [] }
        )
        XCTAssertFalse(controller.isScanning)
        XCTAssertEqual(scans.value, 0)

        settings.agentActivityEnabled = true
        XCTAssertTrue(controller.isScanning)
        await waitUntil { scans.value > 0 }
        XCTAssertGreaterThan(scans.value, 0)

        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await settle()
        XCTAssertFalse(controller.isScanning)

        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        await settle()
        XCTAssertTrue(controller.isScanning)

        settings.agentActivityEnabled = false
        XCTAssertFalse(controller.isScanning)
    }

    /// Disable then re-enable with no sessions: the seeding apply must still run, or the next
    /// real needs-you flip is treated as pre-existing and its notification is lost.
    @MainActor
    func testAgentActivityReenableStillSeedsNeedsYouNotifications() async {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.agentActivityEnabled = false
        let scans = ScanCounter()
        let controller = AgentActivityController(
            presentation: NotchPillPresentation(),
            settings: settings,
            activity: activity,
            scanInterval: 0.05,
            scan: { _, _ in scans.increment(); return [] }
        )
        settings.agentActivityEnabled = true
        await waitUntil { !controller.isFirstApply }
        XCTAssertFalse(controller.isFirstApply, "first scan seeds")

        settings.agentActivityEnabled = false
        XCTAssertTrue(controller.isFirstApply, "disabling re-arms seeding")

        let before = scans.value
        settings.agentActivityEnabled = true
        await waitUntil { scans.value > before && !controller.isFirstApply }
        XCTAssertFalse(controller.isFirstApply, "an identical empty scan must still clear the seeding flag")
        settings.agentActivityEnabled = false
    }

    // MARK: Clipboard

    @MainActor
    func testClipboardPollFollowsSettingAndSleepGate() async {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardHistoryEnabled = false
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("desnotch.tests.polling.\(UUID().uuidString)"))
        let controller = ClipboardController(pasteboard: pasteboard, settings: settings, activity: activity)
        XCTAssertFalse(controller.isPolling)

        settings.clipboardHistoryEnabled = true
        XCTAssertTrue(controller.isPolling)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle()
        XCTAssertFalse(controller.isPolling, "a sleeping display stops the 1 Hz poll")

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        XCTAssertTrue(controller.isPolling)

        settings.clipboardHistoryEnabled = false
        XCTAssertFalse(controller.isPolling)
    }

    /// Switching "Show agent task titles" off clears prompt-derived text already on screen at once.
    @MainActor
    func testTurningTaskTitlesOffClearsPublishedTitlesImmediately() async {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.agentActivityEnabled = true
        settings.agentTaskTitlesEnabled = true
        let session = AgentSession(
            source: .claudeCode, projectLabel: "proj", taskTitle: "Secret prompt hint",
            identityKey: "k", state: .working, lastActivity: Date()
        )
        let controller = AgentActivityController(
            presentation: NotchPillPresentation(),
            settings: settings,
            activity: activity,
            scanInterval: 60,
            scan: { _, _ in [session] }
        )
        await waitUntil { controller.sessions.first?.taskTitle != nil }
        XCTAssertEqual(controller.sessions.first?.taskTitle, "Secret prompt hint")

        settings.agentTaskTitlesEnabled = false
        XCTAssertNil(controller.sessions.first?.taskTitle)
        XCTAssertEqual(controller.sessions.first?.projectLabel, "proj")
        settings.agentActivityEnabled = false
    }

    // MARK: Process monitor

    @MainActor
    func testProcessMonitorFollowsSettingAndSleepGate() async {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.processMonitorEnabled = false
        let sampler = FakeSampler(all: [])
        let monitor = ProcessMonitorController(
            settings: settings, activity: activity, sampler: sampler,
            sampleInterval: 0.05, hotSampleInterval: 0.05
        )
        XCTAssertFalse(monitor.isSampling)

        settings.processMonitorEnabled = true
        XCTAssertTrue(monitor.isSampling)
        await waitUntil { sampler.allCalls > 0 }
        XCTAssertGreaterThan(sampler.allCalls, 0)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle()
        XCTAssertFalse(monitor.isSampling)

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        XCTAssertTrue(monitor.isSampling)

        settings.processMonitorEnabled = false
        XCTAssertFalse(monitor.isSampling)
    }

    @MainActor
    func testProcessMonitorSkipsFailedSamplesAndRefreshesOnlyFlaggedPids() {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.processMonitorEnabled = false
        settings.notifyStuckProcess = true
        var notifications: [String] = []
        let monitor = ProcessMonitorController(
            settings: settings, activity: activity, sampler: FakeSampler(all: []),
            notify: { title, _ in notifications.append(title) }
        )

        let busy = { (cpuTime: TimeInterval) in ProcessCPUSnapshot(pid: 42, totalCPUTime: cpuTime, name: "spinner") }
        let start = Date(timeIntervalSince1970: 10_000)
        // Baseline, then 100% CPU across full scans until the streak reaches ten minutes.
        monitor.apply(snapshots: [busy(0)], sampledAt: 0, now: start)
        for step in 1...3 {
            let uptime = TimeInterval(step) * 300
            monitor.apply(snapshots: [busy(uptime)], sampledAt: uptime, now: start.addingTimeInterval(uptime))
        }
        XCTAssertEqual(monitor.hotProcesses.map(\.pid), [42])
        XCTAssertEqual(notifications, ["Process may be stuck"])

        // A partial refresh of the flagged pid that shows it idle clears it immediately.
        monitor.apply(
            snapshots: [busy(900)], sampledAt: 905, now: start.addingTimeInterval(905), queried: [42]
        )
        XCTAssertTrue(monitor.hotProcesses.isEmpty)
    }

    /// CPU time stops during sleep but the streak clock does not: a build that was hot for two
    /// awake minutes must not read as a ten-minute streak on the first sample after a long sleep.
    @MainActor
    func testProcessMonitorRestartsStreaksAfterSleep() async {
        let activity = makeActivity()
        let settings = SettingsStore(defaults: defaults)
        settings.processMonitorEnabled = false
        settings.notifyStuckProcess = true
        var notifications: [String] = []
        let monitor = ProcessMonitorController(
            settings: settings, activity: activity, sampler: FakeSampler(all: []),
            notify: { title, _ in notifications.append(title) }
        )
        let busy = { (cpuTime: TimeInterval) in ProcessCPUSnapshot(pid: 42, totalCPUTime: cpuTime, name: "build") }
        let start = Date(timeIntervalSince1970: 20_000)
        monitor.apply(snapshots: [busy(0)], sampledAt: 0, now: start)
        monitor.apply(snapshots: [busy(60)], sampledAt: 60, now: start.addingTimeInterval(60))
        monitor.apply(snapshots: [busy(120)], sampledAt: 120, now: start.addingTimeInterval(120))
        XCTAssertTrue(monitor.hotProcesses.isEmpty, "two awake minutes is not a stuck process")

        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await settle()
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()

        // 40 wall-clock minutes later, still burning CPU: the first post-wake sample has no
        // baseline, and the streak starts over instead of reading as 40 minutes.
        let wake = start.addingTimeInterval(40 * 60)
        monitor.apply(snapshots: [busy(180)], sampledAt: 180, now: wake)
        monitor.apply(snapshots: [busy(240)], sampledAt: 240, now: wake.addingTimeInterval(60))
        XCTAssertTrue(monitor.hotProcesses.isEmpty)
        XCTAssertTrue(notifications.isEmpty, "no false 'stuck' notification after sleep")
    }

    /// Regression: `@Published` emits before it stores, so the enable sink used to read the old
    /// (off) flag, bail out of `activateIfAuthorized`, and leave the pill on "Checking Reminders…".
    @MainActor
    func testRemindersControllerStartsWhenEnabledAndFollowsTheSleepGate() async {
        let settings = SettingsStore(defaults: defaults)
        settings.remindersEnabled = false
        let controller = RemindersController(
            permissionRequestsEnabled: false,
            settings: settings,
            activity: makeActivity(),
            authorizationStatus: { 3 }
        )
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertEqual(controller.accessState, .undetermined)

        settings.remindersEnabled = true
        XCTAssertEqual(controller.accessState, .granted, "enabling activates from the delivered value")
        XCTAssertTrue(controller.isRefreshing)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle()
        XCTAssertFalse(controller.isRefreshing, "no tick while the displays sleep")

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        XCTAssertTrue(controller.isRefreshing)

        settings.remindersEnabled = false
        XCTAssertFalse(controller.isRefreshing)
        XCTAssertNil(controller.nextReminder)
    }

    /// Regression: access granted in System Settings after a denial was never noticed (the
    /// one-shot request latch) until relaunch; activation now re-reads the status.
    @MainActor
    func testCalendarControllerPicksUpAccessGrantedAfterADenial() async {
        let settings = SettingsStore(defaults: defaults)
        settings.calendarEnabled = true
        var status = 2
        let controller = CalendarController(
            permissionRequestsEnabled: true,
            settings: settings,
            activity: makeActivity(),
            authorizationStatus: { status }
        )
        XCTAssertEqual(controller.accessState, .denied)
        XCTAssertFalse(controller.isRefreshing)

        status = 3
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        XCTAssertEqual(controller.accessState, .granted)
        XCTAssertTrue(controller.isRefreshing)

        settings.calendarEnabled = false
        XCTAssertFalse(controller.isRefreshing)
    }

    private final class LockedReading: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (mic: Bool, camera: Bool)
        init(mic: Bool, camera: Bool) { stored = (mic, camera) }
        var value: (mic: Bool, camera: Bool) {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private final class FakeMediaUseSource: MediaUseChangeSource, @unchecked Sendable {
        private let lock = NSLock()
        private let accepts: Bool
        private var change: (@Sendable () -> Void)?
        private var failure: (@Sendable () -> Void)?
        init(accepts: Bool = true) { self.accepts = accepts }
        var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return change != nil }
        func start(onChange: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable () -> Void) -> Bool {
            guard accepts else { return false }
            lock.lock(); change = onChange; failure = onFailure; lock.unlock()
            return true
        }
        func stop() { lock.lock(); change = nil; failure = nil; lock.unlock() }
        func fire() { lock.lock(); let c = change; lock.unlock(); c?() }
        func fail() { lock.lock(); let f = failure; lock.unlock(); f?() }
    }

    private final class ScanCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    private final class FakeSampler: ProcessSampling, @unchecked Sendable {
        private let lock = NSLock()
        private let all: [ProcessCPUSnapshot]?
        private var calls = 0
        init(all: [ProcessCPUSnapshot]?) { self.all = all }
        var allCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func snapshotAll() async -> [ProcessCPUSnapshot]? {
            recordCall()
            return all
        }
        private func recordCall() { lock.lock(); calls += 1; lock.unlock() }
        func snapshot(pids: [Int32]) async -> [ProcessCPUSnapshot]? { all }
    }
}
