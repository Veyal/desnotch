import Darwin
import Foundation

// Verified against the installed Hermes Python source (read-only; line numbers re-checked):
// - acp/meta.py:29 protocol version constant is 1
// - acp_adapter/server.py:834 a text-only prompt whose text starts with "/" is a slash command
// - acp_adapter/session.py:518 `platform_toolsets.acp` selects the ACP tool list
// - acp_adapter/permissions.py:54 builds the permission tool call (`raw_input` command); the option
//   list is assembled at permissions.py:42 and includes the once and deny ids plus the session and always option ids
// - acp_adapter/tools.py:811 titles are "<name>: <preview>"; the start event leaves status unset
//   (acp/helpers.py:198 default)
// - tools/approval.py:399 `command_allowlist` is a top-level key
// - hermes_cli/profiles.py:290 and :442 a named profile lives at <hermes home>/profiles/<name>
// - hermes_cli/config_defaults.py:1684 unattended mode defaults to deny
//
// P6: this preflight cannot see toolsets Hermes adds on its own even when the ACP toolset list is
// empty (for example a search tool when provider credentials exist, hermes_cli/tools_config.py:512
// composite toolsets, and :661 platform-native recovery). That still fails closed, because such a
// tool is not allowlisted, classifies as T3, and trips the reducer rule that pauses the lane.

protocol ConfigReading: Sendable {
    func read() -> String?
}

protocol FileFlagReading: Sendable {
    func flags() -> UInt32?
}

/// The voice profile declares no toolsets. An entry outside this set refuses the lane.
enum HermesToolsetPolicy {
    static let allowedToolsets: Set<String> = []
}

struct VoiceProfileConfigReader: ConfigReading {
    func read() -> String? {
        try? String(contentsOf: HermesLocator.voiceProfileConfigURL(), encoding: .utf8)
    }
}

struct VoiceProfileFlagReader: FileFlagReading {
    func flags() -> UInt32? {
        let path = HermesLocator.voiceProfileConfigURL().path
        var info = stat()
        let result = path.withCString { stat($0, &info) }
        if result != 0 { return nil }
        return info.st_flags
    }
}

enum HermesPreflight {
    static func run(
        locator: HermesLocator,
        configReader: ConfigReading,
        fileFlags: FileFlagReading
    ) -> AgentPreflightResult {
        if locator.hermesURL() == nil { return .refused(.binaryMissing) }
        guard let text = configReader.read() else { return .refused(.profileMissing) }
        let scan: MiniConfigScan
        do {
            scan = try MiniConfigScan(parsing: text)
        } catch {
            return .refused(.approvalsOff)
        }
        if let failure = approvals(scan) { return failure }
        if let failure = allowlist(scan) { return failure }
        if let failure = mcp(scan) { return failure }
        if let failure = toolsets(scan) { return failure }
        guard let flags = fileFlags.flags(), flags & UInt32(UF_IMMUTABLE) != 0 else {
            return .refused(.configNotLocked)
        }
        return .ready(profile: "voice")
    }

    /// Nil means the reported protocol version is one this client speaks.
    static func checkProtocol(_ version: Int) -> AgentPreflightResult? {
        if HermesACP.supportedProtocolVersions.contains(version) { return nil }
        return .refused(.protocolMismatch)
    }

    private static func approvals(_ scan: MiniConfigScan) -> AgentPreflightResult? {
        guard case .map(let map) = scan.value(at: ["approvals"]),
              case .string(let mode) = map["mode"] else {
            return .refused(.approvalsOff)
        }
        let lowered = mode.lowercased()
        if lowered == "manual" || lowered == "smart" { return nil }
        return .refused(.approvalsOff)
    }

    private static func allowlist(_ scan: MiniConfigScan) -> AgentPreflightResult? {
        guard let value = scan.value(at: ["command_allowlist"]) else { return nil }
        if case .list(let items) = value, items.isEmpty { return nil }
        return .refused(.allowlistNotEmpty)
    }

    private static func mcp(_ scan: MiniConfigScan) -> AgentPreflightResult? {
        guard let value = scan.value(at: ["mcp_servers"]) else { return nil }
        switch value {
        case .map(let map) where map.isEmpty: return nil
        case .list(let items) where items.isEmpty: return nil
        default: return .refused(.mcpConfigured)
        }
    }

    private static func toolsets(_ scan: MiniConfigScan) -> AgentPreflightResult? {
        guard case .list(let items) = scan.value(at: ["platform_toolsets", "acp"]) else {
            return .refused(.toolsetOutsideAllowlist)
        }
        for item in items {
            guard case .string(let name) = item, HermesToolsetPolicy.allowedToolsets.contains(name) else {
                return .refused(.toolsetOutsideAllowlist)
            }
        }
        return nil
    }
}
