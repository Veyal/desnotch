import Foundation

final class DiskFileWriter: FileWriting, Sendable {
    init() {}

    func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func appendLine(_ line: String, to url: URL) throws {
        let content = Data((line + "\n").utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            let created = FileManager.default.createFile(
                atPath: url.path,
                contents: content,
                attributes: [.posixPermissions: 0o600]
            )
            if !created {
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: content)
        }
    }

    func readLines(from url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func restrictToOwner(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return
        }
        let permissions: NSNumber = isDir.boolValue ? 0o700 : 0o600
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func fileSize(_ url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.intValue ?? 0
    }

    func moveItem(at source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
