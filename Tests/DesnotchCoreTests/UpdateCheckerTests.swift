import XCTest
@testable import DesnotchCore

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("0.4.1", newerThan: "0.4.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0", newerThan: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("0.4.0.1", newerThan: "0.4"))
        XCTAssertFalse(UpdateChecker.isVersion("0.4.0", newerThan: "0.4.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.3.9", newerThan: "0.4.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.4", newerThan: "0.4.0"))
    }

    func testNonNumericComponentsCountAsZero() {
        XCTAssertTrue(UpdateChecker.isVersion("0.4.1", newerThan: "0.4.beta"))
        XCTAssertFalse(UpdateChecker.isVersion("0.4.beta", newerThan: "0.4.1"))
    }
}
