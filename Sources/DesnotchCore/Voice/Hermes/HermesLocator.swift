import Foundation

/// Finds the `hermes` executable and the voice profile path. It never creates or edits either.
struct HermesLocator: Sendable {
    private let candidates: [URL]
    private let isExecutable: @Sendable (URL) -> Bool

    init(
        candidates: [URL] = HermesLocator.defaultCandidates,
        isExecutable: @escaping @Sendable (URL) -> Bool = HermesLocator.defaultIsExecutable
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
    }

    func hermesURL() -> URL? {
        candidates.first(where: isExecutable)
    }

    /// `~/.hermes/profiles/voice/config.yaml`. Layout from `hermes_cli/profiles.py`.
    static func voiceProfileConfigURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".hermes/profiles/voice/config.yaml")
    }

    private static let defaultCandidates: [URL] = [
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".local/bin/hermes"),
        URL(fileURLWithPath: "/opt/homebrew/bin/hermes"),
        URL(fileURLWithPath: "/usr/local/bin/hermes")
    ]

    private static let defaultIsExecutable: @Sendable (URL) -> Bool = { url in
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}
