import XCTest
@testable import DesnotchCore

final class UtteranceNormalizerTests: XCTestCase {
    func testN1_play() {
        XCTAssertEqual(UtteranceNormalizer.tokens("Play"), ["play"])
    }

    func testN2_pauseMusicPlease() {
        XCTAssertEqual(UtteranceNormalizer.tokens("  PAUSE music, please. "), ["pause", "music"])
    }

    func testN3_volumeToThirtyPercent() {
        XCTAssertEqual(UtteranceNormalizer.tokens("Volume to 30%"), ["volume", "to", "30"])
    }

    func testN4_twentyFiveHyphen() {
        XCTAssertEqual(UtteranceNormalizer.tokens("twenty-five"), ["twenty", "five"])
    }

    func testN5_heyDesnotchVolume() {
        XCTAssertEqual(UtteranceNormalizer.tokens("hey desnotch volume 20"), ["volume", "20"])
    }

    func testN6_tolongBukaSafariDong() {
        XCTAssertEqual(UtteranceNormalizer.tokens("tolong buka safari dong"), ["buka", "safari"])
    }

    func testN7_umOnly() {
        XCTAssertEqual(UtteranceNormalizer.tokens("um"), [])
    }

    func testN8_pleaseOnly() {
        XCTAssertEqual(UtteranceNormalizer.tokens("please"), [])
    }

    func testN9_empty() {
        XCTAssertEqual(UtteranceNormalizer.tokens(""), [])
    }

    func testN10_apostropheSplits() {
        XCTAssertEqual(UtteranceNormalizer.tokens("What's the weather?"),
                       ["what", "s", "the", "weather"])
    }

    func testN11_trailingNow() {
        XCTAssertEqual(UtteranceNormalizer.tokens("Open the Pod Bay Doors, now!"),
                       ["open", "the", "pod", "bay", "doors"])
    }

    func testN12_unMute() {
        XCTAssertEqual(UtteranceNormalizer.tokens("un-mute"), ["un", "mute"])
    }

    func testN13_newlineAndRepeatedSpaces() {
        XCTAssertEqual(UtteranceNormalizer.tokens("Buka   aplikasi\nKalender"),
                       ["buka", "aplikasi", "kalender"])
    }

    func testN14_repeatedFillers() {
        XCTAssertEqual(UtteranceNormalizer.tokens("okay okay volume 5"), ["volume", "5"])
    }
}
