import Foundation

public final class AgentCommandAudit: @unchecked Sendable {
    private let url: URL; private let maxBytes: Int; private let lock = NSLock()
    public init(url: URL, maxBytes: Int = 256 * 1024) { self.url = url; self.maxBytes = max(1024, maxBytes) }
    public func record(event: String, outcome: String, policy: String? = nil, byteCount: Int? = nil) {
        var object: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "event": event, "outcome": outcome]
        if let policy { object["policy"] = policy }; if let byteCount { object["byteCount"] = byteCount }
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        lock.lock(); defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.size] as? NSNumber)?.intValue ?? 0 > maxBytes {
            let rotated = url.appendingPathExtension("1"); try? FileManager.default.removeItem(at: rotated); try? FileManager.default.moveItem(at: url, to: rotated)
        }
        var line = data; line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            FileManager.default.createFile(
                atPath: url.path,
                contents: line,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
