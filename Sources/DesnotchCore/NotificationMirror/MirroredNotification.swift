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
    /// texts). Returns nil for descriptions with no readable text - callers treat
    /// that as "not a banner" (e.g. the Notification Center sidebar).
    ///
    /// App identification: the FIRST chunk (in banner order) whose lowercased text
    /// matches a name in `runningAppNames` wins - so a browser-delivered web
    /// notification ("Google Chrome, WhatsApp, John: hi") stays attributed to the
    /// browser and is never promoted to the site's native app, while a sender-first
    /// layout ("John, hi, Telegram") still finds the real app. With no match the
    /// first chunk is assumed to be the app name (Sequoia's documented layout) -
    /// covering apps that aren't running (APNs-delivered) or name drift. Known
    /// blind spot, accepted: a contact named exactly like a running app can win the
    /// scan when the true app chunk matches nothing.
    public static func parse(
        rawDescription: String,
        runningAppNames: Set<String> = [],
        receivedAt: Date = Date()
    ) -> MirroredNotification? {
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
        guard !chunks.isEmpty else { return nil }
        let appIndex = chunks.firstIndex { runningAppNames.contains($0.lowercased()) } ?? 0
        let appName = collapse(chunks[appIndex])
        var rest = chunks
        rest.remove(at: appIndex)
        // Some banners repeat timestamps like "now" or "1m ago" as a trailing chunk;
        // they're noise at 64 chars, not worth special-casing - the cap handles it.
        return MirroredNotification(
            appName: appName,
            content: sanitizeContent(rest.joined(separator: ", ")),
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
