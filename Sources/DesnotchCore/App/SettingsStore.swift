import Foundation

/// User-toggleable feature switches, UserDefaults-backed, all on by default.
/// The pill view gates its sections on these; pollers (process monitor, calendar,
/// agent scanner) also check them so disabled features stop doing background work.
/// `notifyAgentNeedsYou` shares its key with `AgentAttentionNotifier.isEnabled`.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var nowPlayingEnabled: Bool { didSet { set("nowPlayingEnabled", nowPlayingEnabled) } }
    @Published public var agentActivityEnabled: Bool { didSet { set("agentActivityEnabled", agentActivityEnabled) } }
    @Published public var calendarEnabled: Bool { didSet { set("calendarEnabled", calendarEnabled) } }
    @Published public var processMonitorEnabled: Bool { didSet { set("processMonitorEnabled", processMonitorEnabled) } }
    @Published public var trayEnabled: Bool { didSet { set("trayEnabled", trayEnabled) } }
    @Published public var volumeScrollEnabled: Bool { didSet { set("volumeScrollEnabled", volumeScrollEnabled) } }
    @Published public var notifyAgentNeedsYou: Bool { didSet { set(AgentAttentionNotifier.defaultsKey, notifyAgentNeedsYou) } }

    private init() {
        nowPlayingEnabled = Self.get("nowPlayingEnabled")
        agentActivityEnabled = Self.get("agentActivityEnabled")
        calendarEnabled = Self.get("calendarEnabled")
        processMonitorEnabled = Self.get("processMonitorEnabled")
        trayEnabled = Self.get("trayEnabled")
        volumeScrollEnabled = Self.get("volumeScrollEnabled")
        notifyAgentNeedsYou = Self.get(AgentAttentionNotifier.defaultsKey)
    }

    private static func get(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func set(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
