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
    /// Finder icons for items without a QuickLook thumbnail, resolved off the main thread so
    /// a row's SwiftUI body never touches LaunchServices or the filesystem (a sleeping
    /// external or network volume would otherwise stall the open/close spring).
    @Published public private(set) var finderIcons: [URL: NSImage] = [:]

    /// Shown for the instant before a Finder icon arrives, and for anything that never gets one.
    private static let placeholderIcon = NSWorkspace.shared.icon(for: .data)

    private static let defaultsKey = "trayItems"
    public static let maxItems = 8
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let openHandler: (URL) -> Bool
    private let revealHandler: ([URL]) -> Bool
    /// Row icon is 14pt; render at 2x for Retina.
    private let thumbnailSize = CGSize(width: 28, height: 28)

    /// Action dependencies are injectable so the path validation and action wiring can be
    /// tested without opening Finder or another application.
    public init(
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        openHandler: ((URL) -> Bool)? = nil,
        revealHandler: (([URL]) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.openHandler = openHandler ?? { NSWorkspace.shared.open($0) }
        self.revealHandler = revealHandler ?? {
            NSWorkspace.shared.activateFileViewerSelecting($0)
            return true
        }
        let paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        items = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if items.count != paths.count {
            persist()
        }
        items.forEach(generateThumbnail)
        items.forEach(loadFinderIcon)
    }

    public func add(_ url: URL) {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        guard !items.contains(url) else { return }
        items.insert(url, at: 0)
        if items.count > Self.maxItems {
            let evicted = items.suffix(from: Self.maxItems)
            items.removeLast(evicted.count)
            for url in evicted {
                thumbnails[url] = nil
                finderIcons[url] = nil
            }
        }
        generateThumbnail(for: url)
        loadFinderIcon(for: url)
        persist()
    }

    public func remove(_ url: URL) {
        items.removeAll { $0 == url }
        thumbnails[url] = nil
        finderIcons[url] = nil
        persist()
    }

    /// Opens a tray item with its default application.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard isLiveTrayItem(url) else { return false }
        return openHandler(url)
    }

    /// Reveals a tray item in Finder without changing or moving the file.
    @discardableResult
    public func revealInFinder(_ url: URL) -> Bool {
        guard isLiveTrayItem(url) else { return false }
        return revealHandler([url])
    }

    /// Copies tray item references to the pasteboard. Finder receives file URLs, so this is
    /// a real copy/paste operation and never duplicates or moves the underlying files.
    @discardableResult
    public func copyToPasteboard(_ urls: [URL]) -> Bool {
        let validURLs = urls.filter(isLiveTrayItem)
        guard !validURLs.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(validURLs as [NSURL])
    }

    /// Removes missing files from the shelf and returns the surviving references.
    @discardableResult
    public func pruneDeadItems() -> [URL] {
        let liveItems = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard liveItems.count != items.count else { return items }
        let deadURLs = Set(items).subtracting(liveItems)
        items = liveItems
        deadURLs.forEach {
            thumbnails[$0] = nil
            finderIcons[$0] = nil
        }
        persist()
        return liveItems
    }

    /// Best icon for a row: QuickLook thumbnail if one rendered, else the (pre-resolved)
    /// Finder icon, else a generic document icon. A pure dictionary lookup: safe in a body.
    public func icon(for url: URL) -> NSImage {
        thumbnails[url] ?? finderIcons[url] ?? Self.placeholderIcon
    }

    private func loadFinderIcon(for url: URL) {
        let path = url.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let icon = NSWorkspace.shared.icon(forFile: path)
            Task { @MainActor [weak self] in
                guard let self, self.items.contains(url) else { return }
                self.finderIcons[url] = icon
            }
        }
    }

    private func generateThumbnail(for url: URL) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: thumbnailSize, scale: 2, representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return } // no preview for this type: Finder icon is used
            let image = rep.nsImage
            Task { @MainActor [weak self] in
                self?.storeThumbnail(image, for: url)
            }
        }
    }

    /// Keeps a rendered thumbnail only while its item is still on the shelf: a render that
    /// finishes after `remove`/`prune` must not re-insert an entry nothing will ever evict.
    func storeThumbnail(_ image: NSImage, for url: URL) {
        guard items.contains(url) else { return }
        thumbnails[url] = image
    }

    private func persist() {
        defaults.set(items.map(\.path), forKey: Self.defaultsKey)
    }

    private func isLiveTrayItem(_ url: URL) -> Bool {
        url.isFileURL && items.contains(url) && FileManager.default.fileExists(atPath: url.path)
    }
}
