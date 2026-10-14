import AppKit
import Foundation

/// An app the `open_app` tool resolved, by bundle id. Never a path the model typed.
struct AgentAppMatch: Equatable, Sendable {
    var bundleID: String
    var name: String
}

/// A snapshot for `get_system_info`. Every field is optional: a desktop has no battery, and
/// nothing may be playing.
struct AgentSystemSnapshot: Equatable, Sendable {
    var date: Date
    var timeZone: String
    var batteryPercent: Int?
    var batteryCharging: Bool?
    var diskFreeBytes: Int64?
    var frontmostApp: String?
    var nowPlayingTitle: String?
    var nowPlayingArtist: String?
    var nowPlayingIsPlaying: Bool?
}

/// Everything the tools need from AppKit and the app's controllers. Main-actor because it
/// drives `NSWorkspace`, `NSPasteboard` and the local executor.
@MainActor
protocol AgentSystemServing: AnyObject, Sendable {
    /// The existing local verbs (media, volume, timer) through `SystemLocalExecutor`.
    func execute(_ intent: LocalIntent) async -> LocalExecutionResult
    func resolveApp(_ query: String) -> AgentAppMatch?
    func launchApp(_ match: AgentAppMatch) async -> Bool
    func open(_ url: URL) -> Bool
    /// Nil when the clipboard holds no plain text, or a password manager marked it private.
    func readClipboard() -> String?
    func writeClipboard(_ text: String) -> Bool
    func snapshot() -> AgentSystemSnapshot
}

/// Production services. `nowPlaying` and `battery` are read at call time from the app's
/// controllers; the pasteboard is the general one.
@MainActor
final class LiveAgentSystem: AgentSystemServing {
    private let executor: LocalExecuting
    private let nowPlaying: () -> NowPlayingInfo?
    private let battery: () -> BatteryController.BatteryState?

    init(
        executor: LocalExecuting,
        nowPlaying: @escaping () -> NowPlayingInfo?,
        battery: @escaping () -> BatteryController.BatteryState?
    ) {
        self.executor = executor
        self.nowPlaying = nowPlaying
        self.battery = battery
    }

    func execute(_ intent: LocalIntent) async -> LocalExecutionResult {
        await executor.execute(intent)
    }

    /// The fixed catalog first (spoken names), then an exact bundle id, then an app whose
    /// bundle name matches in the standard application folders. No fuzzy matching.
    func resolveApp(_ query: String) -> AgentAppMatch? {
        let tokens = UtteranceNormalizer.tokens(query)
        if let entry = AppCatalog.lookup(tokens) {
            return AgentAppMatch(bundleID: entry.bundleID, name: entry.displayName)
        }
        let workspace = NSWorkspace.shared
        if query.contains("."), !query.contains("/"),
           let url = workspace.urlForApplication(withBundleIdentifier: query),
           let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            return AgentAppMatch(bundleID: id, name: url.deletingPathExtension().lastPathComponent)
        }
        let wanted = query.lowercased()
        let folders = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".app") {
                let base = String(name.dropLast(4))
                guard base.lowercased() == wanted else { continue }
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
                return AgentAppMatch(bundleID: id, name: base)
            }
        }
        return nil
    }

    func launchApp(_ match: AgentAppMatch) async -> Bool {
        await WorkspaceAppLauncher().launch(bundleID: match.bundleID)
    }

    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func readClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let types = Set(pasteboard.types ?? [])
        guard types.isDisjoint(with: ClipboardController.privateTypes) else { return nil }
        return pasteboard.string(forType: .string)
    }

    func writeClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func snapshot() -> AgentSystemSnapshot {
        let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let power = battery()
        let playing = nowPlaying()
        return AgentSystemSnapshot(
            date: Date(),
            timeZone: TimeZone.current.identifier,
            batteryPercent: power?.percent,
            batteryCharging: power?.isCharging,
            diskFreeBytes: disk?.volumeAvailableCapacityForImportantUsage,
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            nowPlayingTitle: playing?.title,
            nowPlayingArtist: playing?.artist,
            nowPlayingIsPlaying: playing?.isPlaying
        )
    }
}
