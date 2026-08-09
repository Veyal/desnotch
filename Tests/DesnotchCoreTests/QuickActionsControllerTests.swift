import XCTest
@testable import DesnotchCore

final class QuickActionsControllerTests: XCTestCase {
    func testCaffeinateArgumentsPreventDisplaySleepAndFollowAppLifetime() {
        XCTAssertEqual(
            QuickActionsController.caffeinateArguments(parentPID: 42),
            ["-d", "-w", "42"]
        )
    }

    @MainActor
    func testToggleStartsAndStopsOwnedProcess() {
        let controller = QuickActionsController(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )

        XCTAssertFalse(controller.isDisplayAwake)
        controller.toggleDisplayAwake()
        XCTAssertTrue(controller.isDisplayAwake)
        controller.toggleDisplayAwake()
        XCTAssertFalse(controller.isDisplayAwake)
    }

    @MainActor
    func testLaunchFailureLeavesActionOff() {
        let controller = QuickActionsController(
            executableURL: URL(fileURLWithPath: "/definitely/missing/caffeinate"),
            arguments: []
        )

        controller.toggleDisplayAwake()

        XCTAssertFalse(controller.isDisplayAwake)
    }
}
