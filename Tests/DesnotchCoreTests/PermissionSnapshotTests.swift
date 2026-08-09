import AVFoundation
import EventKit
import XCTest
@testable import DesnotchCore

final class PermissionSnapshotTests: XCTestCase {
    func testMicrophoneAuthorizationMapping() {
        XCTAssertEqual(PermissionSnapshot.microphoneState(for: .notDetermined), .notDetermined)
        XCTAssertEqual(PermissionSnapshot.microphoneState(for: .restricted), .restricted)
        XCTAssertEqual(PermissionSnapshot.microphoneState(for: .denied), .denied)
        XCTAssertEqual(PermissionSnapshot.microphoneState(for: .authorized), .authorized)
    }

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
            microphone: .authorized,
            calendar: .fullAccess
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(object, [
            "accessibility": "trusted",
            "microphone": "authorized",
            "calendar": "fullAccess"
        ])
    }
}
