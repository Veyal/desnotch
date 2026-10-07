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

    func testPreviewMarksTruncationWithAnEllipsisOnlyWhenCut() {
        let long = String(repeating: "word ", count: 30)
        let cut = ClipboardEntry(text: long).preview
        XCTAssertTrue(cut.hasSuffix("\u{2026}"), "the memory-bound cut must be visible at any pill width")
        XCTAssertLessThanOrEqual(cut.unicodeScalars.count, ClipboardEntry.previewScalarLimit + 1)

        let exact = String(repeating: "a", count: ClipboardEntry.previewScalarLimit)
        XCTAssertEqual(ClipboardEntry(text: exact).preview, exact, "text that fits exactly is not marked")
        XCTAssertEqual(ClipboardEntry(text: "short").preview, "short")
        XCTAssertFalse(ClipboardEntry(text: "short").preview.hasSuffix("\u{2026}"))
    }

    @MainActor
    func testStatusMenuExposesCopyAndRemoveForEveryEntry() {
        let entries = (1...ClipboardController.maxEntries).map {
            ClipboardEntry(text: "entry \($0)")
        }
        let menu = StatusMenuBuilder.makeClipboardSubmenu(entries: entries, privacy: false, target: NSObject())

        XCTAssertEqual(menu.items.count, ClipboardController.maxEntries + 2)
        for (entry, item) in zip(entries, menu.items.prefix(ClipboardController.maxEntries)) {
            XCTAssertEqual(item.title, entry.preview)
            XCTAssertEqual(item.submenu?.items.map(\.title), ["Copy", "Remove from Clipboard History"])
            XCTAssertEqual(item.submenu?.items.map { $0.representedObject as? String }, [
                entry.id.uuidString,
                entry.id.uuidString
            ])
        }
        XCTAssertTrue(menu.items[ClipboardController.maxEntries].isSeparatorItem)
        XCTAssertEqual(menu.items.last?.title, "Clear Clipboard History")
    }
}
