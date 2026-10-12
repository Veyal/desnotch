import XCTest
@testable import DesnotchCore

final class AuditChainTests: XCTestCase {
    func testFiveRecordsVerifyValid() throws {
        var lines: [String] = []
        var prevHash = ""
        var lastHash = ""

        for seq in 1...5 {
            let draft = AuditDraft(kind: .route, lane: .local, tier: .t0, decision: "ok", outcome: "step\(seq)")
            let record = try AuditChain.makeRecord(from: draft, seq: seq, timestamp: "2026-10-12T20:25:0\(seq)Z", prevHash: prevHash)
            let line = try AuditChain.line(for: record)
            lines.append(line)
            prevHash = record.hash
            lastHash = record.hash
        }

        let verification = AuditChain.verify(lines: lines)
        XCTAssertTrue(verification.isValid)
        XCTAssertEqual(verification.recordCount, 5)
        XCTAssertNil(verification.firstBrokenSeq)
        XCTAssertEqual(verification.headHash, lastHash)
    }

    func testAlteringRecordDecisionBreaksChainAtThatRecord() throws {
        var records: [AuditRecord] = []
        var lines: [String] = []
        var prevHash = ""

        for seq in 1...5 {
            let draft = AuditDraft(kind: .route, lane: .local, tier: .t0, decision: "dec\(seq)", outcome: "out\(seq)")
            let record = try AuditChain.makeRecord(from: draft, seq: seq, timestamp: "2026-10-12T20:25:0\(seq)Z", prevHash: prevHash)
            records.append(record)
            lines.append(try AuditChain.line(for: record))
            prevHash = record.hash
        }

        // Alter record 3's decision without recomputing hash
        var corrupted = records[2]
        corrupted.decision = "tampered"
        lines[2] = try AuditChain.line(for: corrupted)

        let verification = AuditChain.verify(lines: lines)
        XCTAssertFalse(verification.isValid)
        XCTAssertEqual(verification.recordCount, 2)
        XCTAssertEqual(verification.firstBrokenSeq, 3)
        XCTAssertEqual(verification.headHash, records[1].hash)
    }

    func testDeletingRecordTwoBreaksChainAtRecordThree() throws {
        var records: [AuditRecord] = []
        var lines: [String] = []
        var prevHash = ""

        for seq in 1...5 {
            let draft = AuditDraft(kind: .route, lane: .local, tier: .t0, decision: "dec\(seq)", outcome: "out\(seq)")
            let record = try AuditChain.makeRecord(from: draft, seq: seq, timestamp: "2026-10-12T20:25:0\(seq)Z", prevHash: prevHash)
            records.append(record)
            lines.append(try AuditChain.line(for: record))
            prevHash = record.hash
        }

        lines.remove(at: 1) // delete record 2

        let verification = AuditChain.verify(lines: lines)
        XCTAssertFalse(verification.isValid)
        XCTAssertEqual(verification.recordCount, 1)
        XCTAssertEqual(verification.firstBrokenSeq, 3)
        XCTAssertEqual(verification.headHash, records[0].hash)
    }

    func testSwappingRecordsTwoAndThreeBreaksChain() throws {
        var records: [AuditRecord] = []
        var lines: [String] = []
        var prevHash = ""

        for seq in 1...5 {
            let draft = AuditDraft(kind: .route, lane: .local, tier: .t0, decision: "dec\(seq)", outcome: "out\(seq)")
            let record = try AuditChain.makeRecord(from: draft, seq: seq, timestamp: "2026-10-12T20:25:0\(seq)Z", prevHash: prevHash)
            records.append(record)
            lines.append(try AuditChain.line(for: record))
            prevHash = record.hash
        }

        lines.swapAt(1, 2)

        let verification = AuditChain.verify(lines: lines)
        XCTAssertFalse(verification.isValid)
        XCTAssertEqual(verification.recordCount, 1)
        XCTAssertEqual(verification.firstBrokenSeq, 3)
        XCTAssertEqual(verification.headHash, records[0].hash)
    }

    func testGarbageLineAtLineFourBreaksChain() throws {
        var records: [AuditRecord] = []
        var lines: [String] = []
        var prevHash = ""

        for seq in 1...5 {
            let draft = AuditDraft(kind: .route, lane: .local, tier: .t0, decision: "dec\(seq)", outcome: "out\(seq)")
            let record = try AuditChain.makeRecord(from: draft, seq: seq, timestamp: "2026-10-12T20:25:0\(seq)Z", prevHash: prevHash)
            records.append(record)
            lines.append(try AuditChain.line(for: record))
            prevHash = record.hash
        }

        lines[3] = "this is not json"

        let verification = AuditChain.verify(lines: lines)
        XCTAssertFalse(verification.isValid)
        XCTAssertEqual(verification.recordCount, 3)
        XCTAssertEqual(verification.firstBrokenSeq, 4)
        XCTAssertEqual(verification.headHash, records[2].hash)
    }

    func testFirstRecordWithNonEmptyPrevHashAndSeqSevenIsAccepted() throws {
        let prevHash = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
        let draft = AuditDraft(kind: .route, lane: .local, tier: .t1, decision: "resume")
        let record = try AuditChain.makeRecord(from: draft, seq: 7, timestamp: "2026-10-12T20:25:00Z", prevHash: prevHash)
        let line = try AuditChain.line(for: record)

        let verification = AuditChain.verify(lines: [line])
        XCTAssertTrue(verification.isValid)
        XCTAssertEqual(verification.recordCount, 1)
        XCTAssertNil(verification.firstBrokenSeq)
        XCTAssertEqual(verification.headHash, record.hash)
    }

    func testLineNeverContainsTranscriptOrPath() throws {
        let secretUtterance = "SecretUtterance12345"
        let draft = AuditDraft(kind: .submit, lane: .hermes, tier: .t1, transcript: secretUtterance)
        let record = try AuditChain.makeRecord(from: draft, seq: 1, timestamp: "2026-10-12T20:25:00Z", prevHash: "")
        let line = try AuditChain.line(for: record)

        XCTAssertFalse(line.contains(secretUtterance))
        XCTAssertFalse(line.contains("/Users/"))
        XCTAssertFalse(line.contains("Library"))
    }

    func testTranscriptHashMatchesKnownVector() throws {
        let draft = AuditDraft(kind: .submit, transcript: "  Hello \n")
        let record = try AuditChain.makeRecord(from: draft, seq: 1, timestamp: "2026-10-12T20:25:00Z", prevHash: "")
        XCTAssertEqual(record.transcriptHash, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testTierIsEncodedAsInteger() throws {
        let draft = AuditDraft(kind: .execute, tier: .t2)
        let record = try AuditChain.makeRecord(from: draft, seq: 1, timestamp: "2026-10-12T20:25:00Z", prevHash: "")
        XCTAssertEqual(record.tier, 2)
        let line = try AuditChain.line(for: record)
        XCTAssertTrue(line.contains("\"tier\":2"))
    }

    func testBlankLinesDoNotBreakChain() throws {
        let draft1 = AuditDraft(kind: .route, decision: "step1")
        let r1 = try AuditChain.makeRecord(from: draft1, seq: 1, timestamp: "2026-10-12T20:25:01Z", prevHash: "")
        let l1 = try AuditChain.line(for: r1)

        let draft2 = AuditDraft(kind: .route, decision: "step2")
        let r2 = try AuditChain.makeRecord(from: draft2, seq: 2, timestamp: "2026-10-12T20:25:02Z", prevHash: r1.hash)
        let l2 = try AuditChain.line(for: r2)

        let lines = [l1, "", "   \t  ", l2, ""]
        let verification = AuditChain.verify(lines: lines)
        XCTAssertTrue(verification.isValid)
        XCTAssertEqual(verification.recordCount, 2)
        XCTAssertEqual(verification.headHash, r2.hash)
    }

    func testWhitespaceOnlyTranscriptYieldsNilHash() throws {
        let draft = AuditDraft(kind: .route, transcript: "   \t\n  ")
        let record = try AuditChain.makeRecord(from: draft, seq: 1, timestamp: "2026-10-12T20:25:00Z", prevHash: "")
        XCTAssertNil(record.transcriptHash)
    }

    func testDecisionSanitizationUnicodeScalars() throws {
        // One emoji (e.g. 🚀, 1 scalar), one slash (/), and one combining accent (e.g. e + \u{0301})
        let raw = "a🚀b/c" + "e\u{0301}" + "d"
        let sanitized = AuditChain.sanitize(raw)
        // 'a' (allowed), '🚀' -> '_', 'b' (allowed), '/' -> '_', 'c' (allowed), 'e' (allowed), '\u{0301}' -> '_', 'd' (allowed)
        XCTAssertEqual(sanitized, "a_b_ce_d")
    }
}
