import EventKit
import XCTest
@testable import DesnotchCore

final class PermissionSnapshotTests: XCTestCase {
    func testCalendarAuthorizationMappingAcrossSupportedVersions() {
        let states: [(Int, PermissionSnapshot.AuthorizationState)] = [
            (0, .notDetermined),
            (1, .restricted),
            (2, .denied),
            (3, .fullAccess),
            (4, .writeOnly),
            (99, .unknown)
        ]
        for (rawValue, expected) in states {
            let status = EKAuthorizationStatus(rawValue: rawValue)!
            XCTAssertEqual(PermissionSnapshot.calendarState(for: status), expected)
        }
    }

    func testSnapshotJSONUsesStablePublicLabels() throws {
        let snapshot = PermissionSnapshot(
            accessibility: .trusted,
            calendar: .fullAccess,
            reminders: .denied
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(object, [
            "accessibility": "trusted",
            "calendar": "fullAccess",
            "reminders": "denied"
        ])
    }
}
