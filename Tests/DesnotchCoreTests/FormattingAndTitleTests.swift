import XCTest
@testable import DesnotchCore

final class TimeFormattingTests: XCTestCase {
    func testClockUnderAnHour() {
        XCTAssertEqual(TimeFormatting.clock(0), "0:00")
        XCTAssertEqual(TimeFormatting.clock(65), "1:05")
        XCTAssertEqual(TimeFormatting.clock(3599), "59:59")
    }

    func testClockOverAnHour() {
        XCTAssertEqual(TimeFormatting.clock(3600), "1:00:00")
        XCTAssertEqual(TimeFormatting.clock(4525), "1:15:25")
        XCTAssertEqual(TimeFormatting.clock(2 * 3600 + 5), "2:00:05")
    }

    func testClockClampsNegative() {
        XCTAssertEqual(TimeFormatting.clock(-3), "0:00")
    }
}

final class TaskTitleSanitizationTests: XCTestCase {
    func testPlainPromptPassesThrough() {
        XCTAssertEqual(AgentActivityScanner.sanitizeTitle("fix the login bug"), "fix the login bug")
    }

    func testTruncatesTo48WithEllipsis() {
        let long = String(repeating: "a", count: 60)
        let title = AgentActivityScanner.sanitizeTitle(long)
        XCTAssertEqual(title?.count, 49) // 48 + ellipsis
        XCTAssertTrue(title?.hasSuffix("…") == true)
    }

    func testRejectsHarnessNoise() {
        XCTAssertNil(AgentActivityScanner.sanitizeTitle("<system-reminder>stuff</system-reminder>"))
        XCTAssertNil(AgentActivityScanner.sanitizeTitle("<command-name>/foo</command-name>"))
        XCTAssertNil(AgentActivityScanner.sanitizeTitle("Caveat: the messages below were generated"))
        XCTAssertNil(AgentActivityScanner.sanitizeTitle("   \n\n  "))
    }

    func testFirstNonEmptyLineAndWhitespaceCollapse() {
        XCTAssertEqual(
            AgentActivityScanner.sanitizeTitle("\n\n  run   the    tests  \nand more"),
            "run the tests"
        )
    }
}

final class NowPlayingTimestampTests: XCTestCase {
    func testISOFractionalTimestampParses() {
        let info = NowPlayingInfo(adapterPayload: [
            "title": "x", "elapsedTime": 10.0, "duration": 100.0,
            "timestamp": "2026-07-31T01:02:03.500Z"
        ])
        XCTAssertEqual(info.elapsed, 10)
        XCTAssertEqual(info.duration, 100)
        XCTAssertEqual(
            info.elapsedAt.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-07-31T01:02:03Z")!.timeIntervalSince1970 + 0.5,
            accuracy: 0.001
        )
    }

    func testEpochTimestampParses() {
        let info = NowPlayingInfo(adapterPayload: ["title": "x", "timestamp": 1_700_000_000.0])
        XCTAssertEqual(info.elapsedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testGarbageTimestampFallsBackToNow() {
        let before = Date()
        let info = NowPlayingInfo(adapterPayload: ["title": "x", "timestamp": "not-a-date"])
        XCTAssertGreaterThanOrEqual(info.elapsedAt, before)
    }

    func testPositionFrozenWhilePausedAndExtrapolatedWhilePlaying() {
        var payload: [String: Any] = [
            "title": "x", "elapsedTime": 30.0, "duration": 100.0,
            "timestamp": Date().timeIntervalSince1970 - 5
        ]
        payload["playing"] = false
        let paused = NowPlayingInfo(adapterPayload: payload)
        XCTAssertEqual(paused.position(at: Date())!, 30, accuracy: 0.01)

        payload["playing"] = true
        let playing = NowPlayingInfo(adapterPayload: payload)
        XCTAssertEqual(playing.position(at: Date())!, 35, accuracy: 0.5)
    }

    func testPositionClampsToDuration() {
        let info = NowPlayingInfo(adapterPayload: [
            "title": "x", "playing": true, "elapsedTime": 99.0, "duration": 100.0,
            "timestamp": Date().timeIntervalSince1970 - 60
        ])
        XCTAssertEqual(info.position(at: Date())!, 100, accuracy: 0.001)
    }
}
