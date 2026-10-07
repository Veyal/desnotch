import ServiceManagement
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

    func testVersionComparisonEdgeCases() {
        // Numeric, not lexicographic.
        XCTAssertTrue(UpdateChecker.isVersion("0.10.0", newerThan: "0.9.0"))
        XCTAssertFalse(UpdateChecker.isVersion("0.9.0", newerThan: "0.10.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.0", newerThan: "0.99.99"))
        // Equal versions with different component counts are not "newer".
        XCTAssertFalse(UpdateChecker.isVersion("1", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1"))
        // Non-numeric components count as 0.
        XCTAssertFalse(UpdateChecker.isVersion("1.x", newerThan: "1.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.1", newerThan: "1.x"))
    }

    func testNormalizedVersionEdgeCases() {
        XCTAssertEqual(UpdateChecker.normalizedVersion("0.10.0"), "0.10.0")
        XCTAssertEqual(UpdateChecker.normalizedVersion("7"), "7")
        XCTAssertNil(UpdateChecker.normalizedVersion("vv1.0"))
        XCTAssertNil(UpdateChecker.normalizedVersion(".1"))
        XCTAssertNil(UpdateChecker.normalizedVersion("1."))
        XCTAssertNil(UpdateChecker.normalizedVersion("1.0+build5"))
    }

    func testChecksRequireTheSettingAndARealBundleVersion() {
        XCTAssertTrue(UpdateChecker.shouldCheck(enabled: true, bundleVersion: "0.10.0"))
        XCTAssertFalse(UpdateChecker.shouldCheck(enabled: false, bundleVersion: "0.10.0"))
        XCTAssertFalse(UpdateChecker.shouldCheck(enabled: true, bundleVersion: nil))
        XCTAssertFalse(UpdateChecker.shouldCheck(enabled: true, bundleVersion: "dev"))
    }

    /// Regression: `@Published` emits before it stores, so the settings sink used to re-read
    /// the old (off) value and the documented "turning it back on checks immediately" never fired.
    @MainActor
    func testTurningCheckForUpdatesBackOnChecksImmediately() throws {
        let suite = "desnotch.tests.updatechecker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.checkForUpdates = false

        var requests = 0
        let checker = UpdateChecker(
            settings: settings,
            bundleVersion: "0.10.0",
            schedulesDailyCheck: false,
            requestHook: { _ in requests += 1 }
        )
        XCTAssertEqual(requests, 0, "disabled: the launch check makes no request")

        settings.checkForUpdates = true
        XCTAssertEqual(requests, 1, "re-enabling checks immediately")

        settings.checkForUpdates = false
        XCTAssertEqual(requests, 1, "disabling makes no request")
        withExtendedLifetime(checker) {}
    }

    @MainActor
    func testLaunchAtLoginStateMapping() {
        XCTAssertEqual(LaunchAtLogin.state(for: .enabled), .enabled)
        XCTAssertEqual(LaunchAtLogin.state(for: .notRegistered), .disabled)
        XCTAssertEqual(LaunchAtLogin.state(for: .requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLogin.state(for: .notFound), .unavailable)
        XCTAssertTrue(LaunchAtLogin.State.requiresApproval.isRegistered)
        XCTAssertFalse(LaunchAtLogin.State.disabled.isRegistered)
        XCTAssertNotNil(LaunchAtLogin.State.requiresApproval.explanation)
        XCTAssertNil(LaunchAtLogin.State.enabled.explanation)
    }
}
