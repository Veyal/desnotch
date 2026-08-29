import AppKit
import XCTest
@testable import DesnotchCore

final class ClipboardControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        let suffix = UUID().uuidString
        suiteName = "desnotch.tests.clipboard.\(suffix)"
        defaults = UserDefaults(suiteName: suiteName)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("desnotch.tests.clipboard.\(suffix)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        pasteboard.clearContents()
        super.tearDown()
    }

    @MainActor
    func testCapturesPlainTextInMemoryAndDeduplicates() {
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardHistoryEnabled = true
        let controller = ClipboardController(pasteboard: pasteboard, settings: settings)

        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        controller.scanNow()
        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        controller.scanNow()
        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        controller.scanNow()

        XCTAssertEqual(controller.entries.map(\.text), ["first", "second"])
    }

    @MainActor
    func testSkipsConcealedAndOversizedValues() {
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardHistoryEnabled = true
        let controller = ClipboardController(pasteboard: pasteboard, settings: settings)

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString("secret", forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        controller.scanNow()

        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "x", count: ClipboardController.maxTextBytes + 1), forType: .string)
        controller.scanNow()

        XCTAssertTrue(controller.entries.isEmpty)
    }

    @MainActor
    func testDisablingClearsHistoryAndStopsCapture() {
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardHistoryEnabled = true
        let controller = ClipboardController(pasteboard: pasteboard, settings: settings)
        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        controller.scanNow()
        XCTAssertEqual(controller.entries.count, 1)

        settings.clipboardHistoryEnabled = false
        XCTAssertTrue(controller.entries.isEmpty)
        pasteboard.clearContents()
        pasteboard.setString("ignored", forType: .string)
        controller.scanNow()
        XCTAssertTrue(controller.entries.isEmpty)
    }

    @MainActor
    func testCopyPreservesOriginalText() {
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardHistoryEnabled = true
        let controller = ClipboardController(pasteboard: pasteboard, settings: settings)
        let original = "first\nsecond"
        pasteboard.clearContents()
        pasteboard.setString(original, forType: .string)
        controller.scanNow()

        guard let id = controller.entries.first?.id else {
            return XCTFail("Expected a captured clipboard entry")
        }
        controller.copy(id)

        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    func testPreviewRemovesLineAndBidirectionalControls() {
        let entry = ClipboardEntry(text: "safe\u{202E}txt\nnext")
        XCTAssertEqual(entry.preview, "safe txt next")
    }
}
