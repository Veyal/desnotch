import XCTest
@testable import DesnotchCore

final class NowPlayingInfoTests: XCTestCase {
    func testEmptyPayloadHasNoContent() {
        let info = NowPlayingInfo(adapterPayload: [:])
        XCTAssertFalse(info.hasContent)
        XCTAssertNil(info.title)
        XCTAssertNil(info.artist)
        XCTAssertFalse(info.isPlaying)
        XCTAssertNil(info.uniqueIdentifier)
    }

    func testTitleArtistMeansContent() {
        let info = NowPlayingInfo(adapterPayload: [
            "title": "Track", "artist": "Artist", "playing": true
        ])
        XCTAssertTrue(info.hasContent)
        XCTAssertEqual(info.title, "Track")
        XCTAssertEqual(info.artist, "Artist")
        XCTAssertTrue(info.isPlaying)
    }

    func testNSNullUniqueIdentifierIsNilNotLiteral() {
        // The adapter can return NSNull for uniqueIdentifier; it must not become "<null>".
        let info = NowPlayingInfo(adapterPayload: ["title": "T", "uniqueIdentifier": NSNull()])
        XCTAssertNil(info.uniqueIdentifier)
        XCTAssertNotEqual(info.uniqueIdentifier, "<null>")
    }

    func testNSNumberIdentifierCoercedToString() {
        let info = NowPlayingInfo(adapterPayload: ["title": "T", "uniqueIdentifier": NSNumber(value: 12345)])
        XCTAssertEqual(info.uniqueIdentifier, "12345")
    }

    func testBundleIdentifierParticipatesInEquality() {
        // Same title/artist playing but reported by a different app => a real change.
        var a = NowPlayingInfo(adapterPayload: ["title": "T", "artist": "A", "bundleIdentifier": "com.x"])
        var b = NowPlayingInfo(adapterPayload: ["title": "T", "artist": "A", "bundleIdentifier": "com.y"])
        XCTAssertNotEqual(a, b)
        b = a
        XCTAssertEqual(a, b)
        // Mutate to satisfy compiler that these aren't constants in some toolchains.
        a.isPlaying.toggle()
    }

    func testIsPlayingFlipBreaksEquality() {
        let a = NowPlayingInfo(adapterPayload: ["title": "T", "playing": true])
        let b = NowPlayingInfo(adapterPayload: ["title": "T", "playing": false])
        XCTAssertNotEqual(a, b)
    }
}
