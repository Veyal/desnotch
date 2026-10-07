import Foundation

/// Shared scan infrastructure for `AgentActivityScanner`: bounded per-path caches, the turn-state
/// cache, task-title sanitising, and the byte-level transcript readers every session source uses.
extension AgentActivityScanner {
    // MARK: - Caches

    /// A session file's cwd, task title, and (Codex) header metadata never change once
    /// written, but used to be re-read and re-JSON-parsed on every 5s scan (~290KB per
    /// Claude session, up to 1MB per Codex header). Cache them by path. Only
    /// successfully-derived cwd/header values are cached - a nil one may simply not exist
    /// *yet* in a brand-new session, so those retry on the next scan. Titles additionally
    /// cache a miss (see `shouldRetryMissingTitle`). Lock-guarded: scans run one at a time
    /// but off the main actor.
    ///
    /// Turn state is a function of (mtime, size) only, so it is cached per path under that
    /// signature: an unchanged transcript is never re-read or re-parsed, including the
    /// "no signal found" verdict that costs a full escalated tail read to establish. Entries
    /// not touched by the latest scan are pruned at its end.
    static let cacheLock = NSLock()
    static var claudeCWDCache: [String: ClaudeFacts] = [:]
    static var codexHeaderCache: [String: (cwd: String?, automation: Bool)] = [:]
    static var titleCache: [String: TitleCacheEntry] = [:]
    static var piCWDCache: [String: String] = [:]
    static var turnCache: [String: TurnCacheEntry] = [:]
    static var scanGeneration: UInt64 = 0

    /// Immutable per-transcript facts read from a Claude Code header line.
    struct ClaudeFacts {
        let cwd: String
        /// `entrypoint: "sdk-cli"` - a headless/orchestrated run, not a person's session.
        let headless: Bool
    }
    struct FileSignature: Equatable {
        let size: UInt64
        let modificationDate: Date
    }
    struct OpenCodeDatabaseSignature: Equatable {
        let path: String
        let database: FileSignature
        let wal: FileSignature?
        let shm: FileSignature?
    }
    struct OpenCodeQueryCacheEntry {
        let signature: OpenCodeDatabaseSignature
        let output: Data
        let queriedAt: Date
    }
    enum TitleCacheEntry {
        case found(String)
        /// No title yet; `scannedSize` is the file size when the head was last scanned.
        case missing(scannedSize: UInt64)
    }
    struct TurnCacheEntry {
        let signature: FileSignature
        let turnInProgress: Bool?
        var generation: UInt64
    }
    enum TurnLookup {
        case found(Bool)
        case none
        /// The file could not be opened/read; never cached so a transient failure retries.
        case unreadable
    }

    static var openCodeQueryCache: OpenCodeQueryCacheEntry?
#if DEBUG
    static var openCodeQueryExecutionCount = 0
#endif
    static let cacheCap = 512

    /// Test/pressure hatch; also keeps unbounded growth impossible.
    static func dropCaches() {
        cacheLock.lock()
        claudeCWDCache.removeAll()
        codexHeaderCache.removeAll()
        titleCache.removeAll()
        piCWDCache.removeAll()
        turnCache.removeAll()
        openCodeQueryCache = nil
#if DEBUG
        openCodeQueryExecutionCount = 0
#endif
        cacheLock.unlock()
    }

#if DEBUG
    static func openCodeQueryExecutionCountForTesting() -> Int {
        cacheLock.lock()
        let count = openCodeQueryExecutionCount
        cacheLock.unlock()
        return count
    }

    static func turnCacheCountForTesting() -> Int {
        cacheLock.lock()
        let count = turnCache.count
        cacheLock.unlock()
        return count
    }
#endif

    static func beginScan() {
        cacheLock.lock()
        scanGeneration &+= 1
        cacheLock.unlock()
    }

    /// Drops turn-cache entries the just-finished scan did not touch (files that aged out of
    /// the lookback window or were deleted). One pass over at most a few hundred entries.
    static func pruneTurnCache() {
        cacheLock.lock()
        let generation = scanGeneration
        turnCache = turnCache.filter { $0.value.generation == generation }
        cacheLock.unlock()
    }

    /// Whether a previously-missing title is worth re-reading. A head scan that was cut short
    /// by `titleHeadBytes` can never find more later (prompts are appended past the window),
    /// so it is final; a scan that covered the whole (small) file only retries once the file
    /// has actually grown. Pure so it is unit-testable.
    static func shouldRetryMissingTitle(scannedSize: UInt64, currentSize: UInt64) -> Bool {
        guard scannedSize < UInt64(titleHeadBytes) else { return false }
        return currentSize != scannedSize
    }

    /// Cached first-prompt title for a transcript. A miss is cached too (and re-read only per
    /// `shouldRetryMissingTitle`), so a transcript with no usable prompt isn't re-read and
    /// re-parsed every 5s tick.
    static func taskTitle(for url: URL, size: UInt64, read: (URL) -> String?) -> String? {
        let key = url.path
        cacheLock.lock()
        let cached = titleCache[key]
        cacheLock.unlock()
        switch cached {
        case .found(let title)?:
            return title
        case .missing(let scannedSize)?:
            if !shouldRetryMissingTitle(scannedSize: scannedSize, currentSize: size) { return nil }
        case nil:
            break
        }

        let title = read(url)
        cacheLock.lock()
        if titleCache.count >= cacheCap { titleCache.removeAll() }
        titleCache[key] = title.map { .found($0) } ?? .missing(scannedSize: size)
        cacheLock.unlock()
        return title
    }

    // MARK: - Task titles

    /// Hard cap for the first-prompt-derived task title shown in the pill. Keep this tight:
    /// the pill is always on screen (and often screenshotted/screen-shared), so it must only
    /// ever show a hint of what the agent is doing, never a full prompt.
    static let taskTitleMax = 48

    /// First non-empty prompt line, whitespace-collapsed and truncated to `taskTitleMax`.
    /// Rejects harness noise: XML-ish wrappers (`<system-reminder>`, `<command-name>`, …)
    /// and Claude Code "Caveat:" preambles.
    /// Internal (not private) so the rejection/truncation rules are unit-testable.
    static func sanitizeTitle(_ raw: String) -> String? {
        guard let firstLine = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        guard !firstLine.hasPrefix("<"), !firstLine.hasPrefix("Caveat:") else { return nil }
        let collapsed = firstLine
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > taskTitleMax else { return collapsed }
        return String(collapsed.prefix(taskTitleMax)) + "…"
    }

    static func fileSignature(_ url: URL) -> FileSignature? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modificationDate = values.contentModificationDate
        else { return nil }
        return FileSignature(size: UInt64(size), modificationDate: modificationDate)
    }

    /// Cached turn state for a transcript, keyed by (mtime, size). Unchanged files cost a stat.
    static func cachedTurnInProgress(
        for url: URL, stamp: FileSignature, signal: ([String: Any]) -> Bool?
    ) -> Bool? {
        let key = url.path
        cacheLock.lock()
        if var entry = turnCache[key], entry.signature == stamp {
            entry.generation = scanGeneration
            turnCache[key] = entry
            cacheLock.unlock()
            return entry.turnInProgress
        }
        cacheLock.unlock()

        let lookup = tailTurnInProgress(url, fileSize: stamp.size, signal: signal)
        let value: Bool?
        switch lookup {
        case .found(let inProgress): value = inProgress
        case .none: value = nil
        case .unreadable: return nil
        }
        cacheLock.lock()
        if turnCache.count >= cacheCap { turnCache.removeAll() }
        turnCache[key] = TurnCacheEntry(signature: stamp, turnInProgress: value, generation: scanGeneration)
        cacheLock.unlock()
        return value
    }

    /// Reads the head of `url` (at most `maxBytes`), or nil if it can't be opened.
    static func readHead(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    /// Whole lines of a head read, as raw bytes. If the read was cut by `maxBytes` the trailing
    /// partial line is dropped at the byte level; nothing is UTF-8 decoded here, so a multibyte
    /// character split by the cut can never fail a decode and discard the whole chunk.
    static func completeLines(in head: Data, maxBytes: Int) -> [Data] {
        var data = head
        if data.count >= maxBytes {
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
            data = data.prefix(through: lastNewline)
        }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    /// Reads bytes from the start of `url` until the first newline, or until `maxBytes` is
    /// reached, and returns the first line (cut at the first 0x0A at the byte level - the chunked
    /// read can end mid-multibyte-character after the newline). Used for JSONL header lines that
    /// can be far larger than a single fixed read (Codex session_meta headers exceed 20 KB).
    /// Returns nil when no newline appears within `maxBytes`.
    static func readFirstLine(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        let chunk = 8192
        while buffer.count < maxBytes {
            let toRead = min(chunk, maxBytes - buffer.count)
            guard let part = try? handle.read(upToCount: toRead), !part.isEmpty else { break }
            buffer.append(part)
            if buffer.contains(0x0A) { break }
        }
        if let newline = buffer.firstIndex(of: 0x0A) {
            return Data(buffer[buffer.startIndex..<newline])
        }
        // No newline: either a still-being-written header (EOF) or an over-long line.
        return buffer.count < maxBytes && !buffer.isEmpty ? buffer : nil
    }

    enum TailRead {
        case lines([Data])
        /// The whole window is one truncated line; a larger window is needed.
        case truncated
        case unreadable
    }

    /// Walks the transcript tail newest-first, escalating the seek window (64 KB -> 1 MB -> 4 MB)
    /// until `signal` settles the turn state. A window that holds lines but no turn signal (long
    /// runs of progress/tool-result entries) escalates too, rather than dropping the session.
    static func tailTurnInProgress(
        _ url: URL, fileSize: UInt64, signal: ([String: Any]) -> Bool?
    ) -> TurnLookup {
        guard fileSize > 0 else { return .none }
        for window in tailWindows {
            switch readTailLines(url: url, fileSize: fileSize, window: window) {
            case .unreadable:
                return .unreadable
            case .truncated:
                break
            case .lines(let lines):
                for line in lines.reversed() {
                    if let obj = parseJSONObject(line), let inProgress = signal(obj) {
                        return .found(inProgress)
                    }
                }
            }
            // The window already covered the whole file; a larger one cannot find more.
            if fileSize <= UInt64(window) { return .none }
        }
        return .none
    }

    /// Reads the last `window` bytes as whole lines (raw bytes, not decoded). The seek is
    /// trimmed to a newline boundary at the byte level, so a multibyte char split by the seek
    /// offset can't corrupt a line.
    static func readTailLines(url: URL, fileSize: UInt64, window: Int) -> TailRead {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }

        let offset = fileSize > UInt64(window) ? fileSize - UInt64(window) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd()
        else { return .unreadable }

        let working: Data
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return .truncated }
            working = data.suffix(from: data.index(after: newline))
        } else {
            working = data
        }
        return .lines(working.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) })
    }

    static func parseJSONObject(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }
}
