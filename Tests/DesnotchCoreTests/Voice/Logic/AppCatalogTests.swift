import XCTest
@testable import DesnotchCore

final class AppCatalogTests: XCTestCase {
    func testSafari() { assertLookup(["safari"], "com.apple.Safari", "Safari") }

    func testChrome() {
        assertLookup(["chrome"], "com.google.Chrome", "Chrome")
        assertLookup(["google", "chrome"], "com.google.Chrome", "Chrome")
    }

    func testTerminal() { assertLookup(["terminal"], "com.apple.Terminal", "Terminal") }

    func testITerm() {
        assertLookup(["iterm"], "com.googlecode.iterm2", "iTerm")
        assertLookup(["iterm2"], "com.googlecode.iterm2", "iTerm")
    }

    func testFinder() { assertLookup(["finder"], "com.apple.finder", "Finder") }

    func testNotes() { assertLookup(["notes"], "com.apple.Notes", "Notes") }

    func testCalendar() {
        assertLookup(["calendar"], "com.apple.iCal", "Calendar")
        assertLookup(["kalender"], "com.apple.iCal", "Calendar")
    }

    func testReminders() { assertLookup(["reminders"], "com.apple.reminders", "Reminders") }

    func testMusic() { assertLookup(["music"], "com.apple.Music", "Music") }

    func testSpotify() { assertLookup(["spotify"], "com.spotify.client", "Spotify") }

    func testMessages() {
        assertLookup(["messages"], "com.apple.MobileSMS", "Messages")
        assertLookup(["pesan"], "com.apple.MobileSMS", "Messages")
    }

    func testMail() { assertLookup(["mail"], "com.apple.mail", "Mail") }

    func testSystemSettings() {
        assertLookup(["system", "settings"], "com.apple.systempreferences", "System Settings")
        assertLookup(["settings"], "com.apple.systempreferences", "System Settings")
        assertLookup(["system", "preferences"], "com.apple.systempreferences", "System Settings")
    }

    func testActivityMonitor() {
        assertLookup(["activity", "monitor"], "com.apple.ActivityMonitor", "Activity Monitor")
    }

    func testCalculator() {
        assertLookup(["calculator"], "com.apple.calculator", "Calculator")
        assertLookup(["kalkulator"], "com.apple.calculator", "Calculator")
    }

    func testPreview() { assertLookup(["preview"], "com.apple.Preview", "Preview") }

    func testVisualStudioCode() {
        assertLookup(["vs", "code"], "com.microsoft.VSCode", "Visual Studio Code")
        assertLookup(["vscode"], "com.microsoft.VSCode", "Visual Studio Code")
        assertLookup(["visual", "studio", "code"], "com.microsoft.VSCode", "Visual Studio Code")
    }

    func testNotion() { assertLookup(["notion"], "notion.id", "Notion") }

    func testTypoSafariIsNil() {
        XCTAssertNil(AppCatalog.lookup(["safar"]))
    }

    func testSafariBrowserIsNil() {
        XCTAssertNil(AppCatalog.lookup(["safari", "browser"]))
    }

    func testActivityAloneIsNil() {
        XCTAssertNil(AppCatalog.lookup(["activity"]))
    }

    func testEmptyIsNil() {
        XCTAssertNil(AppCatalog.lookup([]))
    }

    func testEveryBundleIDIsWellFormed() {
        for entry in catalogEntries {
            XCTAssertFalse(entry.bundleID.isEmpty, entry.bundleID)
            XCTAssertTrue(entry.bundleID.contains("."), entry.bundleID)
            XCTAssertFalse(entry.bundleID.contains(" "), entry.bundleID)
        }
    }

    func testNoBundleIDHasTwoDifferentDisplayNames() {
        var names: [String: String] = [:]
        for entry in catalogEntries {
            if let existing = names[entry.bundleID] {
                XCTAssertEqual(existing, entry.displayName, entry.bundleID)
            } else {
                names[entry.bundleID] = entry.displayName
            }
        }
    }
}

private func assertLookup(_ tokens: [String], _ bundleID: String, _ displayName: String,
                          file: StaticString = #filePath, line: UInt = #line) {
    let entry = AppCatalog.lookup(tokens)
    XCTAssertEqual(entry?.bundleID, bundleID, "\(tokens)", file: file, line: line)
    XCTAssertEqual(entry?.displayName, displayName, "\(tokens)", file: file, line: line)
}

private let catalogEntries: [(bundleID: String, displayName: String)] = [
    ("com.apple.Safari", "Safari"),
    ("com.google.Chrome", "Chrome"),
    ("com.apple.Terminal", "Terminal"),
    ("com.googlecode.iterm2", "iTerm"),
    ("com.apple.finder", "Finder"),
    ("com.apple.Notes", "Notes"),
    ("com.apple.iCal", "Calendar"),
    ("com.apple.reminders", "Reminders"),
    ("com.apple.Music", "Music"),
    ("com.spotify.client", "Spotify"),
    ("com.apple.MobileSMS", "Messages"),
    ("com.apple.mail", "Mail"),
    ("com.apple.systempreferences", "System Settings"),
    ("com.apple.ActivityMonitor", "Activity Monitor"),
    ("com.apple.calculator", "Calculator"),
    ("com.apple.Preview", "Preview"),
    ("com.microsoft.VSCode", "Visual Studio Code"),
    ("notion.id", "Notion")
]
