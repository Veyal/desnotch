import Darwin
import Foundation

/// Tier of a model-supplied web address, shared by `open_url` and `web_fetch`.
/// - Only `http`/`https`; any other scheme (file, app links, javascript) is T3.
/// - Hosts on this Mac or the local network (loopback, private, link-local, CGNAT/tailnet,
///   `.local`, `.ts.net`...) are T3: the agent never reaches local services.
/// - A plain public URL is T1. A URL with a query, credentials, or more than
///   `AgentToolLimits.quietURLLength` characters needs the card (T2), because those are the
///   shapes that can carry data out of the Mac to a third party.
enum AgentURLPolicy {
    struct Verdict: Equatable, Sendable {
        var url: URL
        var tier: VoiceTier
        /// Scanner-sanitized display text for the card.
        var literal: String
        var risk: RiskFlags
        var isTruncated: Bool
    }

    static func classify(_ raw: String) -> Verdict? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased()
        else { return nil }
        let scan = CommandRiskScanner.scan(trimmed)
        func verdict(_ tier: VoiceTier) -> Verdict {
            Verdict(url: url, tier: tier, literal: scan.sanitized, risk: scan.flags.intersection(.hiddenCharacters),
                    isTruncated: scan.wasTruncated)
        }
        if scan.flags.contains(.hiddenCharacters) { return verdict(.t4) }
        guard scheme == "http" || scheme == "https" else { return verdict(.t3) }
        guard let host = url.host, !host.isEmpty else { return nil }
        if isLocalHost(host) { return verdict(.t3) }
        let carriesData = url.query != nil || url.user != nil || url.password != nil
            || trimmed.count > AgentToolLimits.quietURLLength
        return verdict(carriesData ? .t2 : .t1)
    }

    /// Names and literal addresses that point at this Mac or the local network.
    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host.isEmpty || host == "localhost" { return true }
        let localSuffixes = [".localhost", ".local", ".lan", ".internal", ".home.arpa", ".ts.net", ".intranet"]
        if localSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
        if !host.contains(".") && !host.contains(":") { return true }
        if let isPublic = isPublicAddress(host) { return !isPublic }
        return false
    }

    /// Nil when `text` is not a literal IPv4/IPv6 address. Otherwise false for loopback,
    /// private, link-local, CGNAT (Tailscale), multicast, unspecified and reserved ranges.
    static func isPublicAddress(_ text: String) -> Bool? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return isPublicIPv4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return isPublicIPv6(v6)
        }
        return nil
    }

    static func isPublicIPv4(_ address: UInt32) -> Bool {
        let first = address >> 24
        let second = (address >> 16) & 0xFF
        switch first {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(second): return false
        case 169 where second == 254: return false
        case 172 where (16...31).contains(second): return false
        case 192 where second == 168: return false
        case 192 where second == 0 && ((address >> 8) & 0xFF) == 0: return false
        case 198 where second == 18 || second == 19: return false
        case 224...255: return false
        default: return true
        }
    }

    static func isPublicIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }
        if bytes[0] == 0xFF { return false }
        if bytes[0] & 0xFE == 0xFC { return false }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }
        let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        if Array(bytes.prefix(12)) == mappedPrefix {
            let v4 = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return isPublicIPv4(v4)
        }
        return true
    }
}
