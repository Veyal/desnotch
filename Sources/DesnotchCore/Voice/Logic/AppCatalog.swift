import Foundation

// WP-LOGIC owns this file. Base commit: stub with the final signature.

/// The fixed spoken-name to bundle-identifier table. Apps are resolved by exact bundle id
/// only; there is no fuzzy matching.
enum AppCatalog {
    struct Entry: Equatable, Sendable {
        let bundleID: String
        let displayName: String
    }

    private struct Row {
        let aliases: [[String]]
        let bundleID: String
        let displayName: String
    }

    private static let rows: [Row] = [
        Row(aliases: [["safari"]], bundleID: "com.apple.Safari", displayName: "Safari"),
        Row(aliases: [["chrome"], ["google", "chrome"]],
            bundleID: "com.google.Chrome", displayName: "Chrome"),
        Row(aliases: [["terminal"]], bundleID: "com.apple.Terminal", displayName: "Terminal"),
        Row(aliases: [["iterm"], ["iterm2"]],
            bundleID: "com.googlecode.iterm2", displayName: "iTerm"),
        Row(aliases: [["finder"]], bundleID: "com.apple.finder", displayName: "Finder"),
        Row(aliases: [["notes"]], bundleID: "com.apple.Notes", displayName: "Notes"),
        Row(aliases: [["calendar"], ["kalender"]],
            bundleID: "com.apple.iCal", displayName: "Calendar"),
        Row(aliases: [["reminders"]], bundleID: "com.apple.reminders", displayName: "Reminders"),
        Row(aliases: [["music"]], bundleID: "com.apple.Music", displayName: "Music"),
        Row(aliases: [["spotify"]], bundleID: "com.spotify.client", displayName: "Spotify"),
        Row(aliases: [["messages"], ["pesan"]],
            bundleID: "com.apple.MobileSMS", displayName: "Messages"),
        Row(aliases: [["mail"]], bundleID: "com.apple.mail", displayName: "Mail"),
        Row(aliases: [["system", "settings"], ["settings"], ["system", "preferences"]],
            bundleID: "com.apple.systempreferences", displayName: "System Settings"),
        Row(aliases: [["activity", "monitor"]],
            bundleID: "com.apple.ActivityMonitor", displayName: "Activity Monitor"),
        Row(aliases: [["calculator"], ["kalkulator"]],
            bundleID: "com.apple.calculator", displayName: "Calculator"),
        Row(aliases: [["preview"]], bundleID: "com.apple.Preview", displayName: "Preview"),
        Row(aliases: [["vs", "code"], ["vscode"], ["visual", "studio", "code"]],
            bundleID: "com.microsoft.VSCode", displayName: "Visual Studio Code"),
        Row(aliases: [["notion"]], bundleID: "notion.id", displayName: "Notion")
    ]

    /// `tokens` is the already-normalized app-name phrase (e.g. ["activity", "monitor"]).
    /// The whole array must equal one alias; there is no prefix or substring match.
    static func lookup(_ tokens: [String]) -> Entry? {
        guard !tokens.isEmpty else { return nil }
        for row in rows where row.aliases.contains(tokens) {
            return Entry(bundleID: row.bundleID, displayName: row.displayName)
        }
        return nil
    }
}
