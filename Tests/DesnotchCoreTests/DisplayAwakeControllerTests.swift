import XCTest
@testable import DesnotchCore

final class DisplayAwakeControllerTests: XCTestCase {
    func testCaffeinateArgumentsPreventDisplaySleepAndFollowAppLifetime() {
        XCTAssertEqual(
            DisplayAwakeController.caffeinateArguments(parentPID: 42),
            ["-d", "-w", "42"]
        )
    }

    @MainActor
    func testToggleStartsAndStopsOwnedProcess() {
        let controller = DisplayAwakeController(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )

        XCTAssertFalse(controller.isDisplayAwake)
        controller.toggle()
        XCTAssertTrue(controller.isDisplayAwake)
        controller.toggle()
        XCTAssertFalse(controller.isDisplayAwake)
    }

    @MainActor
    func testLaunchFailureLeavesActionOff() {
        let controller = DisplayAwakeController(
            executableURL: URL(fileURLWithPath: "/definitely/missing/caffeinate"),
            arguments: []
        )

        controller.toggle()

        XCTAssertFalse(controller.isDisplayAwake)
    }
}
