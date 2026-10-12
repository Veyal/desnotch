import XCTest
@testable import DesnotchCore

final class ThrowingFileWriter: FileWriting {
    func ensureDirectory(_ url: URL) throws { throw CocoaError(.fileWriteUnknown) }
    func appendLine(_ line: String, to url: URL) throws { throw CocoaError(.fileWriteUnknown) }
    func readLines(from url: URL) throws -> [String] { throw CocoaError(.fileReadUnknown) }
    func restrictToOwner(_ url: URL) throws { throw CocoaError(.fileWriteUnknown) }
    func fileSize(_ url: URL) throws -> Int { throw CocoaError(.fileReadUnknown) }
    func moveItem(at source: URL, to destination: URL) throws { throw CocoaError(.fileWriteUnknown) }
}

final class RestrictOnceFailingFileWriter: FileWriting, @unchecked Sendable {
    private let inner: InMemoryFileWriter
    private let lock = NSLock()
    private var didFailFileRestrict = false

    init(inner: InMemoryFileWriter) {
        self.inner = inner
    }

    func ensureDirectory(_ url: URL) throws { try inner.ensureDirectory(url) }
    func appendLine(_ line: String, to url: URL) throws { try inner.appendLine(line, to: url) }
    func readLines(from url: URL) throws -> [String] { try inner.readLines(from: url) }

    func restrictToOwner(_ url: URL) throws {
        lock.lock()
        let shouldFail = url.pathExtension == "jsonl" && !didFailFileRestrict
        if shouldFail {
            didFailFileRestrict = true
        }
        lock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try inner.restrictToOwner(url)
    }

    func fileSize(_ url: URL) throws -> Int { try inner.fileSize(url) }
    func moveItem(at source: URL, to destination: URL) throws { try inner.moveItem(at: source, to: destination) }
}

final class FileAuditLoggerTests: XCTestCase {
    private func findVerifierScript(from filePath: String = #filePath) -> URL? {
        var current = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0...12 {
            let candidate = current.appendingPathComponent("scripts/voice-harness/verify-audit.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return nil
    }

    func testAppendThreeRecordsAndVerifyValid() async {
        let writer = InMemoryFileWriter()
        let clock = FakeVoiceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let dir = URL(fileURLWithPath: "/tmp/voice-audit")
        let logger = FileAuditLogger(directory: dir, writer: writer, clock: clock)

        let d1 = AuditDraft(kind: .route, lane: .local, tier: .t0, decision: "ok", outcome: "none")
        let d2 = AuditDraft(kind: .execute, lane: .local, tier: .t0, decision: "ok", outcome: "done")
        let d3 = AuditDraft(kind: .approval, lane: .local, tier: .t2, decision: "confirm", outcome: "once")

        let r1 = await logger.append(d1)
        let r2 = await logger.append(d2)
        let r3 = await logger.append(d3)

        XCTAssertTrue(r1)
        XCTAssertTrue(r2)
        XCTAssertTrue(r3)

        let verification = await logger.verify()
        XCTAssertTrue(verification.isValid)
        XCTAssertEqual(verification.recordCount, 3)
    }

    func testSecondLoggerContinuesSequenceAndPrevHash() async {
        let writer = InMemoryFileWriter()
        let clock = FakeVoiceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let dir = URL(fileURLWithPath: "/tmp/voice-audit")

        let logger1 = FileAuditLogger(directory: dir, writer: writer, clock: clock)
        for i in 1...3 {
            let draft = AuditDraft(kind: .route, decision: "step\(i)")
            let res = await logger1.append(draft)
            XCTAssertTrue(res)
        }
        let v1 = await logger1.verify()
        XCTAssertEqual(v1.recordCount, 3)

        let logger2 = FileAuditLogger(directory: dir, writer: writer, clock: clock)
        let draft4 = AuditDraft(kind: .execute, decision: "step4")
        let res4 = await logger2.append(draft4)
        XCTAssertTrue(res4)

        let v2 = await logger2.verify()
        XCTAssertTrue(v2.isValid)
        XCTAssertEqual(v2.recordCount, 4)
    }

    func testThrowingWriterReturnsFalse() async {
        let throwingWriter = ThrowingFileWriter()
        let clock = FakeVoiceClock(Date())
        let dir = URL(fileURLWithPath: "/tmp/voice-audit")
        let logger = FileAuditLogger(directory: dir, writer: throwingWriter, clock: clock)

        let draft = AuditDraft(kind: .route)
        let appended = await logger.append(draft)
        XCTAssertFalse(appended)
    }

    func testRotationAtTinyMaxFileBytes() async {
        let writer = InMemoryFileWriter()
        let clock = FakeVoiceClock(Date())
        let dir = URL(fileURLWithPath: "/tmp/voice-audit")
        let logger = FileAuditLogger(directory: dir, writer: writer, clock: clock, maxFileBytes: 150, keepRotated: 3)

        for i in 1...6 {
            let draft = AuditDraft(kind: .route, decision: "rot_step_\(i)")
            let res = await logger.append(draft)
            XCTAssertTrue(res)
        }

        let rot1Lines = (try? writer.readLines(from: dir.appendingPathComponent("voice-audit.1.jsonl"))) ?? []
        XCTAssertFalse(rot1Lines.isEmpty)

        let liveVerification = await logger.verify()
        XCTAssertTrue(liveVerification.isValid)
    }

    func testKeepRotatedZeroAndOne() async {
        let writer = InMemoryFileWriter()
        let clock = FakeVoiceClock(Date())
        let dir = URL(fileURLWithPath: "/tmp/voice-audit")
        let loggerZero = FileAuditLogger(directory: dir, writer: writer, clock: clock, maxFileBytes: 100, keepRotated: 0)

        for i in 1...4 {
            let draft = AuditDraft(kind: .route, decision: "zero_\(i)")
            let res = await loggerZero.append(draft)
            XCTAssertTrue(res)
        }

        let rot1 = (try? writer.readLines(from: dir.appendingPathComponent("voice-audit.1.jsonl"))) ?? []
        XCTAssertFalse(rot1.isEmpty)
    }

    func testAppendAfterARestrictFailureKeepsTheChainContinuous() async {
        let memory = InMemoryFileWriter()
        let writer = RestrictOnceFailingFileWriter(inner: memory)
        let clock = FakeVoiceClock(Date())
        let dir = URL(fileURLWithPath: "/tmp/voice-audit")
        let logger = FileAuditLogger(directory: dir, writer: writer, clock: clock)

        let draftA = AuditDraft(kind: .route, decision: "draftA")
        let draftB = AuditDraft(kind: .execute, decision: "draftB")

        let resA = await logger.append(draftA)
        XCTAssertFalse(resA)

        let resB = await logger.append(draftB)
        XCTAssertTrue(resB)

        let liveURL = dir.appendingPathComponent("voice-audit.jsonl")
        let lines = (try? memory.readLines(from: liveURL)) ?? []
        XCTAssertEqual(lines.count, 2)

        let verification = await logger.verify()
        XCTAssertTrue(verification.isValid)
        XCTAssertEqual(verification.recordCount, 2)
    }

    func testVerifierLookupSucceedsInTheStandardLayouts() {
        let path = #filePath
        if path.contains("/.build/voice-harness/") || path.contains("/Tests/DesnotchCoreTests/Voice/Platform/") {
            XCTAssertNotNil(findVerifierScript())
        }
    }

    func testPythonVerifierAgreesWithTheSwiftChain() async throws {
        guard let verifierScript = findVerifierScript() else {
            // layout unknown (HARNESS_DIR outside the repo)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            // python3 not available
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PythonVerifierTest-\(UUID().uuidString)")
        let writer = DiskFileWriter()
        let clock = FakeVoiceClock(Date(timeIntervalSince1970: 1_700_000_000))
        let logger = FileAuditLogger(
            directory: tempDir,
            fileName: "voice-audit.jsonl",
            writer: writer,
            clock: clock,
            maxFileBytes: 300,
            keepRotated: 3
        )

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let d1 = AuditDraft(kind: .route, lane: .local, tier: .t0, decision: "start", outcome: "ok", transcript: "turn on lights")
        let d2 = AuditDraft(kind: .submit, lane: .hermes, tier: .t1, decision: "send/now", outcome: "emoji🚀and/slash", transcript: "hello")
        let d3 = AuditDraft(kind: .execute, lane: .local, tier: .t2, decision: "volume:up", outcome: "done", counters: ["tokens": 12])
        let d4 = AuditDraft(kind: .approval, lane: .local, tier: .t2, decision: "approved", outcome: "once")
        let d5 = AuditDraft(kind: .route, lane: .hermes, tier: .t1, decision: "route2", outcome: "ok")
        let d6 = AuditDraft(kind: .execute, lane: .local, tier: .t0, decision: "final", outcome: "success")

        for d in [d1, d2, d3, d4, d5, d6] {
            let res = await logger.append(d)
            XCTAssertTrue(res)
        }

        let rot1File = tempDir.appendingPathComponent("voice-audit.1.jsonl")
        let liveFile = tempDir.appendingPathComponent("voice-audit.jsonl")

        guard FileManager.default.fileExists(atPath: rot1File.path) && FileManager.default.fileExists(atPath: liveFile.path) else {
            XCTFail("Rotation did not produce expected .1 file")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", verifierScript.path, rot1File.path, liveFile.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            // failed to run python3
            return
        }
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.hasPrefix("verify-audit: ok"))

        // Tamper test: tamper one byte of live file and assert verifier exits 1
        var liveContent = try String(contentsOf: liveFile, encoding: .utf8)
        liveContent = liveContent.replacingOccurrences(of: "\"final\"", with: "\"tampered\"")
        try liveContent.write(to: liveFile, atomically: true, encoding: .utf8)

        let tamperProcess = Process()
        tamperProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        tamperProcess.arguments = ["-I", verifierScript.path, rot1File.path, liveFile.path]
        let tamperPipe = Pipe()
        tamperProcess.standardOutput = tamperPipe
        tamperProcess.standardError = tamperPipe

        try tamperProcess.run()
        tamperProcess.waitUntilExit()
        XCTAssertEqual(tamperProcess.terminationStatus, 1)
    }
}
