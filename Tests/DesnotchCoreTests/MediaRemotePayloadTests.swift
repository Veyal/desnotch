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

    func testEmptyGetPayloadIsAuthoritativeSuccess() {
        let json = #"{"payload":{}}"#
        XCTAssertEqual(
            MediaRemoteBridge.getResult(from: Data(json.utf8)),
            .success(nil)
        )
    }

    func testGetAcceptsAdaptersDirectPayloadShape() {
        let json = #"{"title":"Track","artist":"Artist","playing":true}"#
        guard case .success(let info) = MediaRemoteBridge.getResult(from: Data(json.utf8)) else {
            return XCTFail("expected direct get payload to decode")
        }
        XCTAssertEqual(info?.title, "Track")
        XCTAssertEqual(info?.artist, "Artist")
        XCTAssertTrue(info?.isPlaying == true)
    }

    func testDirectEmptyGetPayloadIsAuthoritativeSuccess() {
        XCTAssertEqual(MediaRemoteBridge.getResult(from: Data("{}".utf8)), .success(nil))
    }

    func testMalformedOrFailedGetIsNotAnEmptySuccess() {
        XCTAssertEqual(MediaRemoteBridge.getResult(from: Data("bad".utf8)), .failure)
        let json = #"{"payload":{}}"#
        XCTAssertEqual(
            MediaRemoteBridge.getResult(from: Data(json.utf8), terminationStatus: 1),
            .failure
        )
    }
}
