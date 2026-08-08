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

    func testNormalizedVersion() {
        XCTAssertEqual(UpdateChecker.normalizedVersion(" v0.4.1\n"), "0.4.1")
        XCTAssertEqual(UpdateChecker.normalizedVersion("V1.2"), "1.2")
        XCTAssertNil(UpdateChecker.normalizedVersion(""))
        XCTAssertNil(UpdateChecker.normalizedVersion("v"))
        XCTAssertNil(UpdateChecker.normalizedVersion("1..2"))
        XCTAssertNil(UpdateChecker.normalizedVersion("1.2-beta"))
    }

    func testReleaseVersionRequiresSuccessfulHTTPAndValidTag() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/releases/latest"))
        let validData = try JSONSerialization.data(withJSONObject: ["tag_name": "v1.2.3"])
        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)
        let serverError = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)

        XCTAssertEqual(UpdateChecker.releaseVersion(data: validData, response: success), "1.2.3")
        XCTAssertNil(UpdateChecker.releaseVersion(data: validData, response: redirect))
        XCTAssertNil(UpdateChecker.releaseVersion(data: validData, response: serverError))
        XCTAssertNil(UpdateChecker.releaseVersion(data: Data(), response: success))
        XCTAssertNil(UpdateChecker.releaseVersion(data: Data("{\"tag_name\":\"\"}".utf8), response: success))
        XCTAssertNil(UpdateChecker.releaseVersion(data: Data("{\"tag_name\":\"latest\"}".utf8), response: success))
        XCTAssertNil(UpdateChecker.releaseVersion(data: Data("{\"tag_name\":\"v1..2\"}".utf8), response: success))
    }

    func testRequestTimeoutIsBounded() {
        XCTAssertEqual(UpdateChecker.requestTimeout, 15)
    }

}
