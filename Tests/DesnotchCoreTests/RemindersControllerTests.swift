import Foundation
import XCTest
@testable import DesnotchCore

final class RemindersControllerTests: XCTestCase {
    func testOverdueWinsAndCompletedIsIgnored() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = RemindersController.selectNextReminder(from: [
            .init(id: "future", title: "Future", dueDate: now.addingTimeInterval(60), isAllDay: false),
            .init(id: "done", title: "Done", dueDate: now.addingTimeInterval(-60), isAllDay: false, isCompleted: true),
            .init(id: "late", title: "Late", dueDate: now.addingTimeInterval(-120), isAllDay: false)
        ], now: now)
        XCTAssertEqual(result?.id, "late")
    }

    func testAllDayUsesCalendarDayForOverdue() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 15))!
        let result = RemindersController.selectNextReminder(from: [
            .init(id: "today", title: "Today", dueDate: calendar.startOfDay(for: now), isAllDay: true),
            .init(id: "tomorrow", title: "Tomorrow", dueDate: calendar.date(byAdding: .day, value: 1, to: now)!, isAllDay: true)
        ], now: now, calendar: calendar)
        XCTAssertEqual(result?.id, "today")
        XCTAssertTrue(RemindersController.isUrgent(.init(id: "today", title: "Today", dueDate: calendar.startOfDay(for: now), isAllDay: true), now: now, calendar: calendar))
    }

    func testNearestFutureReminderWinsAndFarFutureIsExcluded() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = RemindersController.selectNextReminder(from: [
            .init(id: "later", title: "Later", dueDate: now.addingTimeInterval(4 * 3600), isAllDay: false),
            .init(id: "soon", title: "Soon", dueDate: now.addingTimeInterval(15 * 60), isAllDay: false),
            .init(id: "next-week", title: "Next week", dueDate: now.addingTimeInterval(8 * 24 * 3600), isAllDay: false)
        ], now: now)

        XCTAssertEqual(result?.id, "soon")
        XCTAssertTrue(RemindersController.isUrgent(
            .init(id: "soon", title: "Soon", dueDate: now.addingTimeInterval(15 * 60), isAllDay: false),
            now: now
        ))
    }

    func testSevenDayAndUrgencyBoundariesAreInclusive() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 12))!
        let sevenDays = calendar.date(byAdding: .day, value: 7, to: now)!
        let outside = sevenDays.addingTimeInterval(1)

        XCTAssertEqual(RemindersController.selectNextReminder(from: [
            .init(id: "outside", title: "Outside", dueDate: outside, isAllDay: false),
            .init(id: "boundary", title: "Boundary", dueDate: sevenDays, isAllDay: false)
        ], now: now, calendar: calendar)?.id, "boundary")

        XCTAssertTrue(RemindersController.isUrgent(
            .init(id: "exact", title: "Exact", dueDate: now.addingTimeInterval(30 * 60), isAllDay: false),
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(RemindersController.isUrgent(
            .init(id: "outside", title: "Outside", dueDate: now.addingTimeInterval(30 * 60 + 1), isAllDay: false),
            now: now,
            calendar: calendar
        ))
    }

    func testEqualDueDatesUseStableIdentifierTieBreak() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let due = now.addingTimeInterval(3600)
        let result = RemindersController.selectNextReminder(from: [
            .init(id: "b", title: "Second", dueDate: due, isAllDay: false),
            .init(id: "a", title: "First", dueDate: due, isAllDay: false)
        ], now: now)
        XCTAssertEqual(result?.id, "a")
    }

    func testSanitizeTitleAndDueLabels() {
        XCTAssertEqual(RemindersController.sanitizeTitle("  Ship\n it\t today  "), "Ship it today")
        XCTAssertEqual(RemindersController.sanitizeTitle("\u{0000}\u{0007}"), "Reminder")
        XCTAssertEqual(RemindersController.sanitizeTitle(String(repeating: "a", count: 200)).count, 120)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RemindersController.dueLabel(now.addingTimeInterval(-1), now: now), "Overdue")
    }

    func testAllDayDueLabelsUseCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 15))!
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        XCTAssertEqual(RemindersController.dueLabel(today, isAllDay: true, now: now, calendar: calendar), "Today")
        XCTAssertEqual(RemindersController.dueLabel(tomorrow, isAllDay: true, now: now, calendar: calendar), "Tomorrow")
        XCTAssertEqual(RemindersController.dueLabel(yesterday, isAllDay: true, now: now, calendar: calendar), "Overdue")
    }
}
