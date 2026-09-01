import AppKit
import XCTest
@testable import DesnotchCore

final class TrayControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        let suffix = UUID().uuidString
        suiteName = "desnotch.tests.tray.\(suffix)"
        defaults = UserDefaults(suiteName: suiteName)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("desnotch.tests.tray.\(suffix)"))
        pasteboard.clearContents()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suffix)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        pasteboard.clearContents()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    func testActionsValidateTrayItemsAndUseInjectedHandlers() {
        let file = makeFile("notes.txt")
        var opened: URL?
        var revealed: [URL] = []
        let controller = TrayController(
            defaults: defaults,
            pasteboard: pasteboard,
            openHandler: { opened = $0; return true },
            revealHandler: { revealed = $0; return true }
        )
        controller.add(file)

        XCTAssertTrue(controller.open(file))
        XCTAssertEqual(opened, file)
        XCTAssertTrue(controller.revealInFinder(file))
        XCTAssertEqual(revealed, [file])

        let outside = directory.appendingPathComponent("outside.txt")
        XCTAssertFalse(controller.open(outside))
        XCTAssertFalse(controller.revealInFinder(outside))
    }

    @MainActor
    func testCopyToPasteboardWritesFileReferencesWithoutMovingFiles() {
        let first = makeFile("one.txt")
        let second = makeFile("two.txt")
        let controller = TrayController(defaults: defaults, pasteboard: pasteboard)
        controller.add(first)
        controller.add(second)

        XCTAssertTrue(controller.copyToPasteboard([first, second]))
        let copied = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL])?.compactMap { $0 as URL }
        XCTAssertEqual(Set(copied ?? []), Set([first, second]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    func testCopyToPasteboardRejectsUnknownOrDeadItems() {
        let file = makeFile("kept.txt")
        let dead = makeFile("removed.txt")
        let controller = TrayController(defaults: defaults, pasteboard: pasteboard)
        controller.add(file)
        controller.add(dead)
        try! FileManager.default.removeItem(at: dead)

        XCTAssertFalse(controller.copyToPasteboard([dead]))
        XCTAssertTrue(controller.copyToPasteboard([file, dead]))
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.count, 1)
    }

    @MainActor
    func testPruneDeadItemsPersistsOnlyLiveReferences() {
        let live = makeFile("live.txt")
        let dead = makeFile("dead.txt")
        let controller = TrayController(defaults: defaults, pasteboard: pasteboard)
        controller.add(live)
        controller.add(dead)
        try! FileManager.default.removeItem(at: dead)

        XCTAssertEqual(controller.pruneDeadItems(), [live])
        XCTAssertEqual(defaults.stringArray(forKey: "trayItems"), [live.path])
    }

    @MainActor
    func testShelfRemainsBoundedToEightItems() {
        let controller = TrayController(defaults: defaults, pasteboard: pasteboard)
        let files = (0..<TrayController.maxItems + 2).map { makeFile("\($0).txt") }
        files.forEach(controller.add)

        XCTAssertEqual(controller.items.count, TrayController.maxItems)
        XCTAssertEqual(controller.items, Array(files.reversed().prefix(TrayController.maxItems)))
    }

    private func makeFile(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(name.utf8))
        return url
    }
}
