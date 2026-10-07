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

    /// Items pushed out by the cap must release their cached icon/thumbnail too.
    @MainActor
    func testEvictedItemsDropCachedIconsAndThumbnails() async {
        let controller = TrayController(defaults: defaults, pasteboard: pasteboard)
        let first = makeFile("first.txt")
        controller.add(first)
        for _ in 0..<100 where controller.finderIcons[first] == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(controller.finderIcons[first])

        (0..<TrayController.maxItems).forEach { controller.add(makeFile("later-\($0).txt")) }
        XCTAssertFalse(controller.items.contains(first))
        XCTAssertNil(controller.finderIcons[first], "eviction drops the cached icon")
        XCTAssertNil(controller.thumbnails[first], "eviction drops the cached thumbnail")
    }

    /// Row bodies must never touch LaunchServices: `icon(for:)` is a dictionary lookup that
    /// falls back to a generic icon until the Finder icon has been resolved off the main thread.
    @MainActor
    func testIconLookupIsCachedAndResolvedOffTheBodyPath() async {
        let file = makeFile("plain.txt")
        let controller = TrayController(defaults: defaults, pasteboard: pasteboard)
        controller.add(file)

        XCTAssertGreaterThan(controller.icon(for: file).size.width, 0, "a placeholder is available at once")
        for _ in 0..<100 where controller.finderIcons[file] == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(controller.finderIcons[file], "the Finder icon is resolved in the background")

        controller.remove(file)
        XCTAssertNil(controller.finderIcons[file], "removal drops the cached icon")
    }

    /// A QuickLook render that finishes after the item was removed must not re-insert a
    /// thumbnail nothing will ever evict.
    @MainActor
    func testLateThumbnailForRemovedItemIsDiscarded() {
        let file = makeFile("late.txt")
        let controller = TrayController(defaults: defaults, pasteboard: pasteboard)
        controller.add(file)
        let image = NSImage(size: NSSize(width: 4, height: 4))

        controller.storeThumbnail(image, for: file)
        XCTAssertNotNil(controller.thumbnails[file], "a live item keeps its render")

        controller.remove(file)
        controller.storeThumbnail(image, for: file)
        XCTAssertNil(controller.thumbnails[file], "a late render for a removed item is dropped")
    }

    private func makeFile(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(name.utf8))
        return url
    }
}
