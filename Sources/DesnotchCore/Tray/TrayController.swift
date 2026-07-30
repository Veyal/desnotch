import Foundation

/// A small file shelf: drop files onto the notch to hold them, drag them out (or click
/// to open) later. Only file *references* (paths) are stored - nothing is copied - and
/// they persist across launches via UserDefaults, with dead paths dropped on load.
@MainActor
public final class TrayController: ObservableObject {
    @Published public private(set) var items: [URL] = []

    private static let defaultsKey = "trayItems"
    private let maxItems = 8

    public init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        items = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func add(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        guard !items.contains(url) else { return }
        items.insert(url, at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
        persist()
    }

    public func remove(_ url: URL) {
        items.removeAll { $0 == url }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: Self.defaultsKey)
    }
}
