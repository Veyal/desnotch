import XCTest
@testable import DesnotchCore

final class DiskFileWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFileWriterTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testDirectoryAndFilePermissions() throws {
        let writer = DiskFileWriter()
        try writer.ensureDirectory(tempDir)
        try writer.restrictToOwner(tempDir)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(dirPerms, 0o700)

        let fileURL = tempDir.appendingPathComponent("test.jsonl")
        try writer.appendLine("line1", to: fileURL)
        try writer.restrictToOwner(fileURL)

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let filePerms = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(filePerms, 0o600)
    }

    func testRoundTripAppendAndRead() throws {
        let writer = DiskFileWriter()
        try writer.ensureDirectory(tempDir)
        let fileURL = tempDir.appendingPathComponent("log.jsonl")

        try writer.appendLine("first line", to: fileURL)
        try writer.appendLine("second line", to: fileURL)

        let lines = try writer.readLines(from: fileURL)
        XCTAssertEqual(lines, ["first line", "second line"])
        XCTAssertGreaterThan(try writer.fileSize(fileURL), 0)
    }

    func testAbsentFileOperations() throws {
        let writer = DiskFileWriter()
        let missingURL = tempDir.appendingPathComponent("nonexistent.jsonl")

        let lines = try writer.readLines(from: missingURL)
        XCTAssertEqual(lines, [])
        XCTAssertEqual(try writer.fileSize(missingURL), 0)
    }

    func testMoveItemOverwritesExistingDestination() throws {
        let writer = DiskFileWriter()
        try writer.ensureDirectory(tempDir)
        let srcURL = tempDir.appendingPathComponent("src.txt")
        let dstURL = tempDir.appendingPathComponent("dst.txt")

        try writer.appendLine("source text", to: srcURL)
        try writer.appendLine("destination text", to: dstURL)

        try writer.moveItem(at: srcURL, to: dstURL)

        let dstLines = try writer.readLines(from: dstURL)
        XCTAssertEqual(dstLines, ["source text"])
        XCTAssertEqual(try writer.readLines(from: srcURL), [])
    }
}
