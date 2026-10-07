import Foundation
import XCTest
@testable import DesnotchCore

final class CalendarControllerTests: XCTestCase {
    func testFindsKnownMeetingURLInNotes() {
        let result = CalendarController.meetingURL(
            explicit: URL(string: "https://example.com/agenda"),
            location: nil,
            notes: "Join at https://meet.google.com/abc-defg-hij when ready."
        )

        XCTAssertEqual(result?.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testPrefersRecognizedExplicitMeetingURL() {
        let result = CalendarController.meetingURL(
            explicit: URL(string: "https://acme.zoom.us/j/123456"),
            location: "https://teams.microsoft.com/l/meetup-join/secondary",
            notes: nil
        )

        XCTAssertEqual(result?.host, "acme.zoom.us")
    }

    func testRejectsUntrustedSchemesAndLookalikeHosts() {
        XCTAssertNil(CalendarController.meetingURL(
            explicit: URL(string: "zoommtg://zoom.us/join?confno=123"),
            location: "https://zoom.us.example.com/j/123",
            notes: "ftp://meet.google.com/room"
        ))
    }

    private func candidate(
        _ title: String,
        start: TimeInterval,
        end: TimeInterval,
        now: Date,
        allDay: Bool = false,
        canceled: Bool = false,
        declined: Bool = false
    ) -> CalendarController.Candidate {
        .init(
            title: title,
            start: now.addingTimeInterval(start),
            end: now.addingTimeInterval(end),
            isAllDay: allDay,
            isCanceled: canceled,
            isDeclinedByCurrentUser: declined,
            joinURL: nil
        )
    }

    func testSelectNextEventSkipsCanceledDeclinedAndAllDay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = CalendarController.selectNextEvent(from: [
            candidate("canceled", start: 60, end: 3600, now: now, canceled: true),
            candidate("declined", start: 120, end: 3600, now: now, declined: true),
            candidate("all-day", start: 180, end: 86_400, now: now, allDay: true),
            candidate("real", start: 7200, end: 10_800, now: now)
        ], now: now)

        XCTAssertEqual(result?.title, "real")
    }

    func testSelectNextEventKeepsOngoingAndDropsEnded() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = CalendarController.selectNextEvent(from: [
            candidate("ended", start: -7200, end: -60, now: now),
            candidate("later", start: 3600, end: 7200, now: now),
            candidate("ongoing", start: -600, end: 1800, now: now)
        ], now: now)

        XCTAssertEqual(result?.title, "ongoing")
    }

    func testSelectNextEventReturnsNilWhenNothingQualifies() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(CalendarController.selectNextEvent(from: [
            candidate("canceled", start: 60, end: 3600, now: now, canceled: true)
        ], now: now))
        XCTAssertNil(CalendarController.selectNextEvent(from: [], now: now))
    }
}
