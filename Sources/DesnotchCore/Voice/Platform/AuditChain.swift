import CryptoKit
import Foundation

enum AuditChain {
    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sanitize(_ string: String?) -> String? {
        guard let string = string else { return nil }
        var scalars: [UnicodeScalar] = []
        for scalar in string.unicodeScalars {
            let v = scalar.value
            let isAlphaNum = (v >= 0x30 && v <= 0x39) || // 0-9
                             (v >= 0x41 && v <= 0x5A) || // A-Z
                             (v >= 0x61 && v <= 0x7A)    // a-z
            let isAllowedPunct = (v == 0x5F) || // _
                                 (v == 0x2E) || // .
                                 (v == 0x3A) || // :
                                 (v == 0x2D)    // -
            if isAlphaNum || isAllowedPunct {
                scalars.append(scalar)
            } else {
                scalars.append(UnicodeScalar(0x5F)) // _
            }
        }
        var result = String(String.UnicodeScalarView(scalars))
        if result.count > 64 {
            result = String(result.prefix(64))
        }
        return result
    }

    static func makeRecord(from draft: AuditDraft, seq: Int, timestamp: String, prevHash: String) throws -> AuditRecord {
        var transcriptHash: String?
        if let text = draft.transcript {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty {
                transcriptHash = sha256Hex(trimmed)
            }
        }

        var record = AuditRecord(
            seq: seq,
            timestamp: timestamp,
            kind: draft.kind,
            lane: draft.lane,
            tier: draft.tier?.rawValue,
            decision: sanitize(draft.decision),
            outcome: sanitize(draft.outcome),
            transcriptHash: transcriptHash,
            counters: draft.counters,
            prevHash: prevHash,
            hash: ""
        )

        record.hash = try hash(for: record)
        return record
    }

    static func line(for record: AuditRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self)
    }

    static func hash(for record: AuditRecord) throws -> String {
        var copy = record
        copy.hash = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let jsonBytes = try encoder.encode(copy)
        let canonicalJSON = String(decoding: jsonBytes, as: UTF8.self)
        let payload = record.prevHash + "\n" + canonicalJSON
        return sha256Hex(payload)
    }

    static func verify(lines: [String]) -> AuditVerification {
        let nonBlankLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !nonBlankLines.isEmpty else {
            return .empty
        }

        let decoder = JSONDecoder()
        var validCount = 0
        var headHash = ""
        var previousRecord: AuditRecord?

        for (idx, line) in nonBlankLines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(AuditRecord.self, from: data) else {
                return AuditVerification(
                    isValid: false,
                    recordCount: validCount,
                    firstBrokenSeq: idx + 1,
                    headHash: headHash
                )
            }

            if let prev = previousRecord {
                if record.seq != prev.seq + 1 || record.prevHash != prev.hash {
                    return AuditVerification(
                        isValid: false,
                        recordCount: validCount,
                        firstBrokenSeq: record.seq,
                        headHash: headHash
                    )
                }
            }

            guard let expectedHash = try? hash(for: record), expectedHash == record.hash else {
                return AuditVerification(
                    isValid: false,
                    recordCount: validCount,
                    firstBrokenSeq: record.seq,
                    headHash: headHash
                )
            }

            validCount += 1
            headHash = record.hash
            previousRecord = record
        }

        return AuditVerification(
            isValid: true,
            recordCount: validCount,
            firstBrokenSeq: nil,
            headHash: headHash
        )
    }
}
