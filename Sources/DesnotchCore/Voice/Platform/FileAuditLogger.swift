import Foundation

final class FileAuditLogger: AuditLogging, @unchecked Sendable {
    private let directory: URL
    private let fileName: String
    private let writer: FileWriting
    private let clock: VoiceClock
    private let maxFileBytes: Int
    private let keepRotated: Int

    private let lock = NSLock()
    private var isStarted = false
    private var seq: Int = 0
    private var lastHash: String = ""

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init(
        directory: URL,
        fileName: String = "voice-audit.jsonl",
        writer: FileWriting,
        clock: VoiceClock,
        maxFileBytes: Int = 1_048_576,
        keepRotated: Int = 4
    ) {
        self.directory = directory
        self.fileName = fileName
        self.writer = writer
        self.clock = clock
        self.maxFileBytes = maxFileBytes
        self.keepRotated = keepRotated
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("desnotch/voice")
    }

    private var liveURL: URL {
        directory.appendingPathComponent(fileName)
    }

    private func rotatedName(_ n: Int) -> String {
        if let dotIndex = fileName.lastIndex(of: ".") {
            let base = fileName[..<dotIndex]
            let ext = fileName[fileName.index(after: dotIndex)...]
            return "\(base).\(n).\(ext)"
        } else {
            return "\(fileName).\(n)"
        }
    }

    private func rotatedURL(_ n: Int) -> URL {
        directory.appendingPathComponent(rotatedName(n))
    }

    private func performLazyStartLocked() throws {
        try writer.ensureDirectory(directory)
        try writer.restrictToOwner(directory)

        let decoder = JSONDecoder()
        var loaded = false

        if let lines = try? writer.readLines(from: liveURL), !lines.isEmpty {
            for line in lines.reversed() {
                if let data = line.data(using: .utf8),
                   let record = try? decoder.decode(AuditRecord.self, from: data) {
                    seq = record.seq
                    lastHash = record.hash
                    loaded = true
                    break
                }
            }
        }

        if !loaded {
            let rot1 = rotatedURL(1)
            if let lines = try? writer.readLines(from: rot1), !lines.isEmpty {
                for line in lines.reversed() {
                    if let data = line.data(using: .utf8),
                       let record = try? decoder.decode(AuditRecord.self, from: data) {
                        seq = record.seq
                        lastHash = record.hash
                        loaded = true
                        break
                    }
                }
            }
        }

        if !loaded {
            seq = 0
            lastHash = ""
        }

        isStarted = true
    }

    private func rotateLocked() throws {
        let k = max(1, keepRotated)
        for i in stride(from: k, through: 2, by: -1) {
            let src = rotatedURL(i - 1)
            let dst = rotatedURL(i)
            if (try? writer.fileSize(src)) ?? 0 > 0 {
                try writer.moveItem(at: src, to: dst)
            }
        }
        if (try? writer.fileSize(liveURL)) ?? 0 > 0 {
            try writer.moveItem(at: liveURL, to: rotatedURL(1))
        }
    }

    private func appendLocked(_ draft: AuditDraft) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if !isStarted {
            do {
                try performLazyStartLocked()
            } catch {
                return false
            }
        }

        let nextSeq = seq + 1
        let timestamp = dateFormatter.string(from: clock.now())
        let record: AuditRecord
        let line: String

        do {
            record = try AuditChain.makeRecord(from: draft, seq: nextSeq, timestamp: timestamp, prevHash: lastHash)
            line = try AuditChain.line(for: record)
        } catch {
            return false
        }

        do {
            if try writer.fileSize(liveURL) >= maxFileBytes {
                try rotateLocked()
            }
        } catch {
            return false
        }

        do {
            try writer.appendLine(line, to: liveURL)
        } catch {
            return false
        }

        seq = record.seq
        lastHash = record.hash

        do {
            try writer.restrictToOwner(liveURL)
            return true
        } catch {
            return false
        }
    }

    private func verifyLocked() -> AuditVerification {
        lock.lock()
        defer { lock.unlock() }

        let lines = (try? writer.readLines(from: liveURL)) ?? []
        return AuditChain.verify(lines: lines)
    }

    @discardableResult
    func append(_ draft: AuditDraft) async -> Bool {
        appendLocked(draft)
    }

    func verify() async -> AuditVerification {
        verifyLocked()
    }
}
