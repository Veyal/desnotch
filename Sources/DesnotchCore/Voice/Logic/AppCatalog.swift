import Foundation

// WP-LOGIC owns this file. Base commit: stub with the final signature.

/// The fixed spoken-name to bundle-identifier table. Apps are resolved by exact bundle id
/// only; there is no fuzzy matching.
enum AppCatalog {
    struct Entry: Equatable, Sendable {
        let bundleID: String
        let displayName: String
    }

    /// `tokens` is the already-normalized app-name phrase (e.g. ["activity", "monitor"]).
    static func lookup(_ tokens: [String]) -> Entry? {
        // STUB (WP-LOGIC replaces this body).
        nil
    }
}
