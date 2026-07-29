import XCTest
@testable import DesnotchCore

final class MediaRemotePayloadTests: XCTestCase {
    func testParsesPayload() {
        let json = #"{"type":"nowPlayingInfo","payload":{"title":"T"}}"#
        let payload = MediaRemoteBridge.payload(from: json.data(using: .utf8)!)
        XCTAssertEqual(payload?["title"] as? String, "T")
    }

    func testMissingPayloadReturnsNil() {
        let json = #"{"type":"somethingElse"}"#
        XCTAssertNil(MediaRemoteBridge.payload(from: json.data(using: .utf8)!))
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(MediaRemoteBridge.payload(from: Data([0x68, 0x65, 0x6c]))) // "hel"
    }

    func testEmptyPayloadPreserved() {
        let json = #"{"payload":{}}"#
        let payload = MediaRemoteBridge.payload(from: json.data(using: .utf8)!)
        XCTAssertEqual(payload?.count, 0)
    }
}
