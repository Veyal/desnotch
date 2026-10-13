import Foundation

/// Where the file tools may look. Injected so tests run against a temporary folder and never
/// the real home directory.
struct AgentPathContext: Equatable, Sendable {
    /// The user's home folder (the T1 read scope, minus hidden folders and `~/Library`).
    var home: URL
    /// desnotch's own scratch folder: the default working directory of every process tool.
    var scratch: URL
    /// Folders no tool may touch at all, besides the shared protected-path markers: desnotch's
    /// own voice state (the audit log), so the agent cannot rewrite its own trail.
    var denied: [URL]

    /// `~`, `~/Library/Application Support/desnotch/agent-scratch`, and the voice audit folder.
    static func live() -> AgentPathContext {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        return AgentPathContext(
            home: home,
            scratch: support.appendingPathComponent("desnotch/agent-scratch", isDirectory: true),
            denied: [FileAuditLogger.defaultDirectory()]
        )
    }

    /// Creates the scratch folder (owner-only) when missing; false when it cannot exist.
    func ensureScratch() -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: scratch.path, isDirectory: &isDirectory) { return isDirectory.boolValue }
        do {
            try manager.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }
}

enum AgentPathAccess: Equatable, Sendable {
    case read
    case write
}

/// The outcome of classifying one model-supplied path.
struct AgentPathVerdict: Equatable, Sendable {
    /// Absolute, standardized, symlinks resolved: the path the tool will actually use.
    var url: URL
    var tier: VoiceTier
}

/// Path policy of the file tools (and of a process tool's working directory):
/// - T4 (no path, ever): anything that names a protected location (the command scanner's
///   shared marker list: `.ssh`, `.hermes`, keychains, credentials, engagement and evidence
///   folders...), before OR after resolving symlinks, any hidden/control character, and
///   desnotch's own voice state.
/// - Read: T1 inside the scratch folder or inside home outside hidden folders and `~/Library`;
///   everything else (dotfiles, `~/Library`, system folders) needs the card (T2).
/// - Write: T2 (card) inside the scratch folder or inside home outside hidden folders and
///   `~/Library`; anything else (dotfiles, launch agents, system folders) is T3, denied in v1,
///   which keeps persistence points out of reach.
enum AgentToolPaths {
    static func classify(_ raw: String, access: AgentPathAccess, context: AgentPathContext) -> AgentPathVerdict? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024 else { return nil }
        guard let url = resolve(trimmed, context: context) else { return nil }
        if CommandRiskScanner.scan(trimmed).flags.contains(.hiddenCharacters)
            || CommandRiskScanner.mentionsProtectedPath(trimmed)
            || CommandRiskScanner.mentionsProtectedPath(url.path)
            || context.denied.contains(where: { isWithin(url, canonical($0)) }) {
            return AgentPathVerdict(url: url, tier: .t4)
        }
        let quiet = isWithin(url, canonical(context.scratch)) || isOrdinaryHomePath(url, home: canonical(context.home))
        switch access {
        case .read: return AgentPathVerdict(url: url, tier: quiet ? .t1 : .t2)
        case .write: return AgentPathVerdict(url: url, tier: quiet ? .t2 : .t3)
        }
    }

    /// `~` and `~/x` expand to home; a relative path is taken inside the scratch folder.
    /// Symlinks are resolved on the deepest existing ancestor, so a link cannot point a quiet
    /// path at a protected one.
    static func resolve(_ raw: String, context: AgentPathContext) -> URL? {
        var path = raw
        if path == "~" {
            path = context.home.path
        } else if path.hasPrefix("~/") {
            path = context.home.path + "/" + path.dropFirst(2)
        } else if path.hasPrefix("~") {
            return nil
        } else if !path.hasPrefix("/") {
            path = context.scratch.path + "/" + path
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        return canonical(standardized)
    }

    /// Resolves symlinks on the deepest ancestor that exists and re-appends the rest.
    static func canonical(_ url: URL) -> URL {
        let manager = FileManager.default
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !manager.fileExists(atPath: existing.path) && existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in tail {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    static func isWithin(_ url: URL, _ folder: URL) -> Bool {
        let path = url.path
        let root = folder.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Inside home, not in `~/Library`, and no hidden component below home.
    static func isOrdinaryHomePath(_ url: URL, home: URL) -> Bool {
        guard isWithin(url, home) else { return false }
        let below = url.pathComponents.dropFirst(home.pathComponents.count)
        if below.first == "Library" { return false }
        return !below.contains { $0.hasPrefix(".") }
    }

    /// `~/…` form for display on a card when the path is inside home.
    static func display(_ url: URL, context: AgentPathContext) -> String {
        let home = canonical(context.home).path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}
