import Foundation

// File tools. Every path goes through `AgentToolPaths` (protected markers, symlinks resolved,
// read/write scopes) both when the call is proposed and again right before it runs.

private func pathProposal(
    _ raw: String?, access: AgentPathAccess, context: AgentPathContext, code: String,
    quietLabel: String, approvedLabel: String, summary: String, literalPrefix: String = ""
) -> ChatToolProposal {
    guard let raw, let verdict = AgentToolPaths.classify(raw, access: access, context: context) else {
        return AgentProposals.invalid(code, label: quietLabel, "a valid path is required")
    }
    let shown = AgentProposals.scanned(literalPrefix + AgentToolPaths.display(verdict.url, context: context))
    return ChatToolProposal(
        tier: verdict.tier,
        stepLabel: verdict.tier >= .t2 ? approvedLabel : quietLabel,
        summary: summary,
        literal: shown.sanitized,
        risk: shown.flags.intersection(.hiddenCharacters),
        isTruncated: shown.wasTruncated,
        auditCode: code
    )
}

/// `list_dir`: names, kinds and sizes of a folder's visible entries, capped. T1 in the read scope.
struct ListDirTool: AgentTool {
    let paths: AgentPathContext
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "list_dir",
            description: "List the files and folders in a folder (use ~ for the home folder).",
            inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        pathProposal(args.text("path"), access: .read, context: paths, code: "tool.list_dir",
                     quietLabel: AgentToolStep.listFolder, approvedLabel: AgentToolStep.listFolderApproved,
                     summary: "List a folder")
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let raw = args.text("path"), let verdict = AgentToolPaths.classify(raw, access: .read, context: paths) else {
            return ChatToolOutcome(content: "Invalid path.", isError: true)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: verdict.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return ChatToolOutcome(content: "Not a readable folder.", isError: true)
        }
        let sorted = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var lines: [String] = []
        var hidden = 0
        for item in sorted {
            if CommandRiskScanner.mentionsProtectedPath(item.path) {
                hidden += 1
                continue
            }
            if lines.count >= AgentToolLimits.listEntries { break }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                lines.append("\(item.lastPathComponent)/")
            } else {
                let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
                lines.append("\(item.lastPathComponent)  \(size)")
            }
        }
        var header = "\(sorted.count - hidden) entries in \(AgentToolPaths.display(verdict.url, context: paths))"
        if sorted.count - hidden > lines.count { header += " (first \(lines.count) shown)" }
        if hidden > 0 { header += "; \(hidden) protected entries withheld" }
        return ChatToolOutcome(content: ([header] + lines).joined(separator: "\n"), isError: false)
    }
}

/// `read_file`: a text file's first lines, capped. Binary files are refused. T1 in the read scope.
struct ReadFileTool: AgentTool {
    let paths: AgentPathContext
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "read_file",
            description: "Read a text file (first lines only).",
            inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"max_lines":{"type":"integer","minimum":1,"maximum":2000}},"required":["path"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        pathProposal(args.text("path"), access: .read, context: paths, code: "tool.read_file",
                     quietLabel: AgentToolStep.readFile, approvedLabel: AgentToolStep.readFileApproved,
                     summary: "Read a file")
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let raw = args.text("path"), let verdict = AgentToolPaths.classify(raw, access: .read, context: paths) else {
            return ChatToolOutcome(content: "Invalid path.", isError: true)
        }
        let values = try? verdict.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            return ChatToolOutcome(content: "Not a readable file.", isError: true)
        }
        guard (values?.fileSize ?? 0) <= AgentToolLimits.readFileBytes,
              let data = try? Data(contentsOf: verdict.url) else {
            return ChatToolOutcome(content: "The file is too large or unreadable.", isError: true)
        }
        if data.prefix(8_192).contains(0) {
            return ChatToolOutcome(content: "That is a binary file.", isError: true)
        }
        let maxLines = min(max(args.int("max_lines") ?? AgentToolLimits.readFileDefaultLines, 1), 2_000)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: .newlines)
        var content = lines.prefix(maxLines).joined(separator: "\n")
        if lines.count > maxLines {
            content += "\n[\(lines.count - maxLines) more lines not shown]"
        }
        return ChatToolOutcome(content: content, isError: false)
    }
}

/// `search_files`: file and folder NAMES containing a query, under a folder (home by default).
/// Hidden folders, `~/Library` (unless it is the folder asked for) and protected locations are
/// never entered; the walk is bounded in depth, entries visited, and results.
struct SearchFilesTool: AgentTool {
    let paths: AgentPathContext
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "search_files",
            description: "Find files or folders whose name contains some text, under a folder (default: home).",
            inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"},"folder":{"type":"string"}},"required":["query"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let query = args.text("query"), query.count <= 200 else {
            return AgentProposals.invalid("tool.search_files", label: AgentToolStep.searchFiles, "query is required")
        }
        if CommandRiskScanner.mentionsProtectedPath(query) {
            return ChatToolProposal(tier: .t4, stepLabel: AgentToolStep.searchFiles, summary: "Search file names",
                                    auditCode: "tool.search_files")
        }
        return pathProposal(args.text("folder") ?? "~", access: .read, context: paths, code: "tool.search_files",
                            quietLabel: AgentToolStep.searchFiles, approvedLabel: AgentToolStep.searchFilesApproved,
                            summary: "Search file names", literalPrefix: "In ")
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let query = args.text("query")?.lowercased(),
              let verdict = AgentToolPaths.classify(args.text("folder") ?? "~", access: .read, context: paths)
        else {
            return ChatToolOutcome(content: "Invalid search.", isError: true)
        }
        let root = verdict.url
        let home = AgentToolPaths.canonical(paths.home)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ChatToolOutcome(content: "Not a readable folder.", isError: true)
        }
        var results: [String] = []
        var visited = 0
        while let item = walker.nextObject() as? URL {
            if Task.isCancelled { return ChatToolOutcome(content: "Cancelled.", isError: true) }
            visited += 1
            if visited > AgentToolLimits.searchVisited || results.count >= AgentToolLimits.searchResults { break }
            let isHomeLibrary = item.path == home.path + "/Library"
            if isHomeLibrary || CommandRiskScanner.mentionsProtectedPath(item.path) {
                walker.skipDescendants()
                continue
            }
            if walker.level >= AgentToolLimits.searchDepth { walker.skipDescendants() }
            if item.lastPathComponent.lowercased().contains(query) {
                results.append(AgentToolPaths.display(item, context: paths))
            }
        }
        if results.isEmpty { return ChatToolOutcome(content: "No matching names found.", isError: false) }
        return ChatToolOutcome(content: results.joined(separator: "\n"), isError: false)
    }
}

/// `write_file`: creates or replaces a text file. Always T2 (card with the exact path and a
/// preview); outside home's ordinary folders T3 (denied); protected T4. The parent folder must
/// already exist, and an existing folder is never replaced.
struct WriteFileTool: AgentTool {
    let paths: AgentPathContext

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "write_file",
            description: "Create or overwrite a text file. The user must approve.",
            inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let raw = args.text("path"), let content = args.string("content"),
              content.utf8.count <= AgentToolLimits.writeBytes,
              let verdict = AgentToolPaths.classify(raw, access: .write, context: paths)
        else {
            return AgentProposals.invalid("tool.write_file", label: AgentToolStep.writeFileApproved,
                                          "path and content (at most 64 KB) are required")
        }
        let exists = FileManager.default.fileExists(atPath: verdict.url.path)
        let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
        let pathText = AgentToolPaths.display(verdict.url, context: paths)
        let detail = "\(exists ? "Replace" : "Create"), \(lines) lines, \(content.utf8.count) bytes"
        let shown = AgentProposals.scanned(pathText)
        let card = AgentProposals.contentCard(header: [shown.sanitized, detail], content: content)
        return ChatToolProposal(
            tier: card.hidden ? .t4 : verdict.tier,
            stepLabel: AgentToolStep.writeFileApproved,
            summary: exists ? "Replace a file" : "Create a file",
            literal: card.literal,
            risk: shown.flags.intersection(.hiddenCharacters),
            isTruncated: shown.wasTruncated || card.isTruncated,
            auditCode: "tool.write_file"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let raw = args.text("path"), let content = args.string("content"),
              content.utf8.count <= AgentToolLimits.writeBytes,
              let verdict = AgentToolPaths.classify(raw, access: .write, context: paths)
        else {
            return ChatToolOutcome(content: "Invalid write.", isError: true)
        }
        var isDirectory: ObjCBool = false
        let parent = verdict.url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ChatToolOutcome(content: "The folder does not exist.", isError: true)
        }
        if FileManager.default.fileExists(atPath: verdict.url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return ChatToolOutcome(content: "That path is a folder.", isError: true)
        }
        do {
            try Data(content.utf8).write(to: verdict.url, options: .atomic)
            return ChatToolOutcome(content: "Wrote \(content.utf8.count) bytes.", isError: false)
        } catch {
            return ChatToolOutcome(content: "Could not write the file.", isError: true)
        }
    }
}
