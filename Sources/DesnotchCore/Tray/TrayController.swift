import AppKit
import Foundation
import QuickLookThumbnailing

/// A small file shelf: drop files onto the notch to hold them, drag them out (or click
/// to open) later. Only file *references* (paths) are stored - nothing is copied - and
/// they persist across launches via UserDefaults, with dead paths dropped on load.
/// Image/document items get a QuickLook thumbnail (async, cached here) so the rows show
/// real previews instead of generic type icons.
@MainActor
public final class TrayController: ObservableObject {
    @Published public private(set) var items: [URL] = []
    @Published public private(set) var thumbnails: [URL: NSImage] = [:]

    private static let defaultsKey = "trayItems"
    private let maxItems = 8
    /// Row icon is 14pt; render at 2x for Retina.
    private let thumbnailSize = CGSize(width: 28, height: 28)

    public init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        items = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        items.forEach(generateThumbnail)
    }

    public func add(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        guard !items.contains(url) else { return }
        items.insert(url, at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
        generateThumbnail(for: url)
        persist()
    }

    public func remove(_ url: URL) {
        items.removeAll { $0 == url }
        thumbnails[url] = nil
        persist()
    }

    /// Best icon for a row: QuickLook thumbnail if one rendered, else the Finder icon.
    public func icon(for url: URL) -> NSImage {
        thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    private func generateThumbnail(for url: URL) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: thumbnailSize, scale: 2, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return } // no preview for this type: Finder icon is used
            Task { @MainActor in
                self?.thumbnails[url] = rep.nsImage
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: Self.defaultsKey)
    }
}
