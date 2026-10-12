import AVFoundation
import Speech
import XCTest
@testable import DesnotchCore

final class SystemVoicePermissionsTests: XCTestCase {
    func testMicrophoneAuthorizationStatusMapping() {
        let cases: [(Int, VoicePermissionState)] = [
            (0, .notDetermined),
            (1, .restricted),
            (2, .denied),
            (3, .authorized),
            (99, .unknown)
        ]
        for (raw, expected) in cases {
            if let status = AVAuthorizationStatus(rawValue: raw) {
                XCTAssertEqual(SystemVoicePermissions.state(forMicrophone: status), expected)
            } else {
                XCTFail("Could not create AVAuthorizationStatus with rawValue \(raw)")
            }
        }
    }

    func testSpeechAuthorizationStatusMapping() {
        let cases: [(Int, VoicePermissionState)] = [
            (0, .notDetermined),
            (1, .denied),
            (2, .restricted),
            (3, .authorized),
            (99, .unknown)
        ]
        for (raw, expected) in cases {
            if let status = SFSpeechRecognizerAuthorizationStatus(rawValue: raw) {
                XCTAssertEqual(SystemVoicePermissions.state(forSpeech: status), expected)
            } else {
                XCTFail("Could not create SFSpeechRecognizerAuthorizationStatus with rawValue \(raw)")
            }
        }
    }

    func testHasUsageDescription() {
        XCTAssertFalse(SystemVoicePermissions.hasUsageDescription(info: nil, key: "TestKey"))

        let emptyInfo: [String: Any] = [:]
        XCTAssertFalse(SystemVoicePermissions.hasUsageDescription(info: emptyInfo, key: "TestKey"))

        let emptyStringInfo: [String: Any] = ["TestKey": ""]
        XCTAssertFalse(SystemVoicePermissions.hasUsageDescription(info: emptyStringInfo, key: "TestKey"))

        let nonStringInfo: [String: Any] = ["TestKey": 123]
        XCTAssertFalse(SystemVoicePermissions.hasUsageDescription(info: nonStringInfo, key: "TestKey"))

        let validInfo: [String: Any] = ["TestKey": "Access required for feature"]
        XCTAssertTrue(SystemVoicePermissions.hasUsageDescription(info: validInfo, key: "TestKey"))
    }
}
