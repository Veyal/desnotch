import XCTest
@testable import DesnotchCore

final class DailyTurnCounterTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        suiteName = "desnotch.voice.turns.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRemainingStartsAtTheLimit() {
        let counter = DailyTurnCounter(defaults: defaults, calendar: calendar)
        XCTAssertEqual(counter.remaining(now: sampleDay), VoiceLimits.hermesTurnsPerDay)
    }

    func testIncrementConsumesOneTurn() {
        var counter = DailyTurnCounter(defaults: defaults, calendar: calendar)
        counter.increment(now: sampleDay)
        XCTAssertEqual(counter.remaining(now: sampleDay), VoiceLimits.hermesTurnsPerDay - 1)
    }

    func testNewDayResetsTheCount() {
        var counter = DailyTurnCounter(defaults: defaults, calendar: calendar)
        counter.increment(now: sampleDay)
        let later = sampleDay.addingTimeInterval(60 * 60 * 48)
        XCTAssertEqual(counter.remaining(now: later), VoiceLimits.hermesTurnsPerDay)
    }

    func testCorruptStoredCountCountsAsZero() {
        var counter = DailyTurnCounter(defaults: defaults, calendar: calendar, limit: 40)
        counter.increment(now: sampleDay)
        defaults.set("nope", forKey: "voice.hermesTurns.count")
        XCTAssertEqual(counter.remaining(now: sampleDay), 40)
    }

    func testRemainingIsNeverNegative() {
        var counter = DailyTurnCounter(defaults: defaults, calendar: calendar, limit: 40)
        counter.increment(now: sampleDay)
        defaults.set(-3, forKey: "voice.hermesTurns.count")
        XCTAssertEqual(counter.remaining(now: sampleDay), 40)
        defaults.set(50, forKey: "voice.hermesTurns.count")
        XCTAssertEqual(counter.remaining(now: sampleDay), 0)
    }

    func testLimitIsHonoured() {
        var counter = DailyTurnCounter(defaults: defaults, calendar: calendar, limit: 2)
        XCTAssertEqual(counter.remaining(now: sampleDay), 2)
        counter.increment(now: sampleDay)
        counter.increment(now: sampleDay)
        XCTAssertEqual(counter.remaining(now: sampleDay), 0)
        counter.increment(now: sampleDay)
        XCTAssertEqual(counter.remaining(now: sampleDay), 0)
    }

    private var sampleDay: Date { Date(timeIntervalSince1970: 1_700_000_000) }
}
