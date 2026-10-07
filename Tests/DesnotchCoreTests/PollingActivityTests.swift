import AppKit
import XCTest
@testable import DesnotchCore

final class PollingActivityTests: XCTestCase {
    private var workspace: NotificationCenter!
    private var processInfo: NotificationCenter!
    private var lowPower = false

    override func setUp() {
        super.setUp()
        workspace = NotificationCenter()
        processInfo = NotificationCenter()
        lowPower = false
    }

    @MainActor
    private func makeActivity() -> PollingActivity {
        PollingActivity(
            workspaceCenter: workspace,
            processInfoCenter: processInfo,
            lowPowerModeProvider: { [unowned self] in self.lowPower }
        )
    }

    /// Observers deliver on the main operation queue; drain it instead of sleeping.
    private func settle() async {
        await drainMainOperationQueue()
    }

    @MainActor
    func testSuspendsWhileDisplaysAsleepAndResumesOnWake() async {
        let activity = makeActivity()
        XCTAssertFalse(activity.isSuspended)

        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle()
        XCTAssertTrue(activity.isSuspended)

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        XCTAssertFalse(activity.isSuspended)
    }

    @MainActor
    func testStaysSuspendedUntilEveryReasonClears() async {
        let activity = makeActivity()
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await settle()
        XCTAssertTrue(activity.isSuspended)

        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        XCTAssertTrue(activity.isSuspended, "session is still inactive")

        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        await settle()
        XCTAssertFalse(activity.isSuspended)
    }

    @MainActor
    func testSystemSleepSuspendsUntilWake() async {
        let activity = makeActivity()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await settle()
        XCTAssertTrue(activity.isSuspended)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        XCTAssertFalse(activity.isSuspended)
    }

    @MainActor
    func testLowPowerModeStretchesIntervals() async {
        let activity = makeActivity()
        XCTAssertEqual(activity.scaled(5), 5, accuracy: 0.0001)

        lowPower = true
        processInfo.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await settle()
        XCTAssertTrue(activity.isLowPowerMode)
        XCTAssertEqual(activity.scaled(5), 5 * PollingActivity.lowPowerIntervalMultiplier, accuracy: 0.0001)

        lowPower = false
        processInfo.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await settle()
        XCTAssertEqual(activity.scaled(5), 5, accuracy: 0.0001)
    }
}
