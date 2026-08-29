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
}
