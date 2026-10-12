import AVFoundation
import EventKit
import Speech
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
            guard let status = EKAuthorizationStatus(rawValue: rawValue) else {
                XCTFail("Could not create EKAuthorizationStatus with rawValue \(rawValue)")
                continue
            }
            XCTAssertEqual(PermissionSnapshot.calendarState(for: status), expected)
        }
    }

    func testMicrophoneAuthorizationMapping() {
        let states: [(Int, PermissionSnapshot.AuthorizationState)] = [
            (0, .notDetermined),
            (1, .restricted),
            (2, .denied),
            (3, .authorized),
            (99, .unknown)
        ]
        for (rawValue, expected) in states {
            guard let status = AVAuthorizationStatus(rawValue: rawValue) else {
                XCTFail("Could not create AVAuthorizationStatus with rawValue \(rawValue)")
                continue
            }
            XCTAssertEqual(PermissionSnapshot.microphoneState(for: status), expected)
        }
    }

    func testSpeechAuthorizationMapping() {
        let states: [(Int, PermissionSnapshot.AuthorizationState)] = [
            (0, .notDetermined),
            (1, .denied),
            (2, .restricted),
            (3, .authorized),
            (99, .unknown)
        ]
        for (rawValue, expected) in states {
            guard let status = SFSpeechRecognizerAuthorizationStatus(rawValue: rawValue) else {
                XCTFail("Could not create SFSpeechRecognizerAuthorizationStatus with rawValue \(rawValue)")
                continue
            }
            XCTAssertEqual(PermissionSnapshot.speechState(for: status), expected)
        }
    }

    func testSnapshotJSONUsesStablePublicLabels() throws {
        let snapshot = PermissionSnapshot(
            accessibility: .trusted,
            calendar: .fullAccess,
            reminders: .denied,
            microphone: .authorized,
            speech: .notDetermined
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(object, [
            "accessibility": "trusted",
            "calendar": "fullAccess",
            "reminders": "denied",
            "microphone": "authorized",
            "speech": "notDetermined"
        ])
    }
}
