import Foundation
import os

/// Polls the GitHub releases API (at launch, then daily) and reports when a release
/// newer than the running bundle version exists. Surfaced as a status-menu item that
/// opens the release page (the user updates via `brew upgrade --cask desnotch`).
/// Bare `swift run` binaries have no bundle version, so dev builds never nag.
@MainActor
public final class UpdateChecker {
    /// Called at most once per newer version discovered, with the version string ("0.4.1").
    public var onUpdateAvailable: ((String) -> Void)?

    public private(set) var availableVersion: String?

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Veyal/desnotch/releases/latest")!
    private let checkInterval: TimeInterval = 24 * 3600
    private let logger = Logger(subsystem: "com.desnotch.app", category: "updates")
    private var timer: Timer?
    private var notifiedVersion: String?

    public init() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") is String else {
            return // dev binary: no version identity, nothing to compare against
        }
        check()
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        let task = URLSession.shared.dataTask(with: Self.latestReleaseURL) { [weak self] data, _, error in
            guard let data,
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = obj["tag_name"] as? String
            else {
                if let error {
                    Task { @MainActor [weak self] in
                        self?.logger.notice("update check failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Self.isVersion(latest, newerThan: current) else { return }
                self.availableVersion = latest
                if self.notifiedVersion != latest {
                    self.notifiedVersion = latest
                    self.onUpdateAvailable?(latest)
                }
            }
        }
        task.resume()
    }

    /// Dotted-numeric comparison ("0.4.1" vs "0.4"); missing components count as 0,
    /// non-numeric components as 0. Public + pure so it's unit-testable.
    nonisolated public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
