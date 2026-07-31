import Foundation

/// One notification banner as mirrored into the pill. Lives only in memory - the
/// content string is never written to disk, logs, or defaults (the same privacy bar
/// as agent task titles: the pill is permanently on screen and screen-shared).
public struct MirroredNotification: Equatable {
    /// The sending app's display name (e.g. "Slack"). App identity is metadata, not
    /// content - it stays visible in privacy mode while `content` is blanked.
    public var appName: String
    /// One sanitized, hard-capped line of the banner's title/body, or nil when the
    /// banner exposed nothing readable beyond the app name.
    public var content: String?
    public var receivedAt: Date

    /// Hard cap on the rendered content line - same philosophy as agent task titles
    /// (`AgentActivityScanner.taskTitleMax`) but a little roomier for message previews.
    public static let contentMax = 64

    /// Parses the raw accessibility description of a banner into app name + content.
    ///
    /// On macOS Sequoia a banner's readable text arrives as either newline-separated
    /// lines or one "AppName, Title, Body" comma-joined line (the SwiftUI Notification
    /// Center exposes `AXAttributedDescription`/`AXDescription`, not per-line static
    /// texts). The first non-empty chunk is the app name; everything after joins into
    /// the content line. Returns nil for descriptions with no readable app name -
    /// callers treat that as "not a banner" (e.g. the Notification Center sidebar).
    public static func parse(rawDescription: String, receivedAt: Date = Date()) -> MirroredNotification? {
        var chunks = rawDescription
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if chunks.count == 1 {
            chunks = chunks[0]
                .components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        guard let first = chunks.first, !first.isEmpty else { return nil }
        let appName = collapse(first)
        // Some banners repeat timestamps like "now" or "1m ago" as a trailing chunk;
        // they're noise at 64 chars, not worth special-casing - the cap handles it.
        let rest = chunks.dropFirst().joined(separator: ", ")
        return MirroredNotification(
            appName: appName,
            content: sanitizeContent(rest),
            receivedAt: receivedAt
        )
    }

    /// Whitespace-collapsed, hard-capped single line, or nil when empty.
    public static func sanitizeContent(_ raw: String) -> String? {
        let collapsed = collapse(raw)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > contentMax else { return collapsed }
        return String(collapsed.prefix(contentMax)) + "…"
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
