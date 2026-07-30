import AppKit
import Foundation

/// Parsed snapshot of one now-playing update from `MediaRemoteBridge`.
///
/// The adapter's JSON keys (`title`, `artist`, `playbackRate`, `artworkData` as
/// base64, etc.) are documented at github.com/ungive/mediaremote-adapter, unlike
/// the private `kMRMediaRemoteNowPlayingInfo*` dictionary keys this project read
/// directly before switching to the adapter. Missing/renamed keys still degrade
/// gracefully to `nil`/defaults rather than crashing.
public struct NowPlayingInfo: Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artwork: NSImage?
    public var isPlaying: Bool
    public var uniqueIdentifier: String?
    /// Which app is reporting; included in equality so a same-title track playing in a
    /// different app (or two sources with no unique id) is detected as a real change.
    public var bundleIdentifier: String?

    /// Track length in seconds, if the source reports one (radio/streams often don't).
    public var duration: TimeInterval?
    /// Playback position in seconds as of `elapsedAt`. Deliberately excluded from
    /// equality - it changes on every delivery and would defeat change detection.
    public var elapsed: TimeInterval?
    /// When `elapsed` was sampled (adapter timestamp, or arrival time as a fallback).
    public var elapsedAt = Date()

    /// Live playback position extrapolated to `date` (frozen while paused).
    public func position(at date: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        guard isPlaying else { return elapsed }
        let extrapolated = elapsed + date.timeIntervalSince(elapsedAt)
        if let duration { return min(extrapolated, duration) }
        return extrapolated
    }

    public static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.isPlaying == rhs.isPlaying
            && lhs.uniqueIdentifier == rhs.uniqueIdentifier
            && lhs.bundleIdentifier == rhs.bundleIdentifier
    }

    /// Whether there is enough information here to be worth showing a pill for.
    public var hasContent: Bool {
        title != nil || artist != nil
    }

    public init(adapterPayload payload: [String: Any]) {
        title = payload["title"] as? String
        artist = payload["artist"] as? String
        album = payload["album"] as? String
        isPlaying = payload["playing"] as? Bool ?? false
        bundleIdentifier = payload["bundleIdentifier"] as? String

        duration = (payload["duration"] as? NSNumber)?.doubleValue
        elapsed = (payload["elapsedTime"] as? NSNumber)?.doubleValue
        elapsedAt = NowPlayingInfo.date(from: payload["timestamp"]) ?? Date()

        // The adapter can hand back an NSNull-wrapped uniqueIdentifier; casting it
        // straight to a String used to produce the literal "<null>", which broke
        // track-change equality. Treat NSNumber/NSNull/empty as "no identifier".
        uniqueIdentifier = NowPlayingInfo.stringIdentifier(from: payload["uniqueIdentifier"])

        if let base64 = payload["artworkData"] as? String,
            let data = Data(base64Encoded: base64)
        {
            artwork = ArtworkCache.downsampled(data: data, for: uniqueIdentifier)
        } else {
            artwork = nil
        }
    }

    /// The adapter's `timestamp` is an ISO 8601 string (with fractional seconds); accept
    /// an epoch number too, and nil for anything else so `elapsedAt` falls back to now.
    private static func date(from value: Any?) -> Date? {
        switch value {
        case let s as String:
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: s) { return date }
            return ISO8601DateFormatter().date(from: s)
        case let n as NSNumber:
            if n === NSNull() { return nil }
            return Date(timeIntervalSince1970: n.doubleValue)
        default:
            return nil
        }
    }

    /// Coerces a now-playing identifier value (which may be String, NSNumber, or
    /// NSNull) into a non-empty String, or nil. Avoids the "<null>" literal that a
    /// naive `"\(value)"` produced for NSNull and broke track-change detection.
    private static func stringIdentifier(from value: Any?) -> String? {
        switch value {
        case let s as String:
            return s.isEmpty ? nil : s
        case let n as NSNumber:
            // Distinguish a real number from NSNull (which is also bridged as NSNumber).
            if n === NSNull() { return nil }
            let s = n.stringValue
            return s.isEmpty ? nil : s
        default:
            return nil
        }
    }
}

/// Decoded-and-downsampled artwork cache.
///
/// The adapter sends the full-resolution artwork (~1 MB) on every update, even on a
/// play/pause flip. Decoding it to an `NSImage` on every tick is wasteful for a 16/24pt
/// view, so decode results are downsampled to a view-appropriate size and cached keyed
/// on the track's `uniqueIdentifier` - a re-delivery of the same track reuses the
/// cached image without re-decoding.
enum ArtworkCache {
    private static let cache = NSCache<NSString, NSImage>()
    private static let maxDimension: CGFloat = 128 // ~64pt @2x, enough for the 24pt view

    static func downsampled(data: Data, for identifier: String?) -> NSImage? {
        let key = identifier ?? data.shaPrefix
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        let image: NSImage?
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            image = NSImage(data: data)
        }
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }
}

private extension Data {
    /// A short, stable key for artwork blobs with no track identifier.
    var shaPrefix: String {
        // First 8 bytes hexed is plenty to distinguish distinct artwork blobs without
        // a real hash dependency; collisions only cost a redundant decode.
        let bytes = prefix(8).map { String(format: "%02x", $0) }.joined()
        return "art-\(bytes)"
    }
}
