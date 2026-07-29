import AppKit
import Foundation

/// Parsed snapshot of one now-playing update from `MediaRemoteBridge`.
///
/// The adapter's JSON keys (`title`, `artist`, `playbackRate`, `artworkData` as
/// base64, etc.) are documented at github.com/ungive/mediaremote-adapter, unlike
/// the private `kMRMediaRemoteNowPlayingInfo*` dictionary keys this project read
/// directly before switching to the adapter. Missing/renamed keys still degrade
/// gracefully to `nil`/defaults rather than crashing.
struct NowPlayingInfo: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: NSImage?
    var isPlaying: Bool
    var uniqueIdentifier: String?

    static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.isPlaying == rhs.isPlaying
            && lhs.uniqueIdentifier == rhs.uniqueIdentifier
    }

    /// Whether there is enough information here to be worth showing a pill for.
    var hasContent: Bool {
        title != nil || artist != nil
    }

    init(adapterPayload payload: [String: Any]) {
        title = payload["title"] as? String
        artist = payload["artist"] as? String
        album = payload["album"] as? String
        isPlaying = payload["playing"] as? Bool ?? false
        uniqueIdentifier = (payload["uniqueIdentifier"].map { "\($0)" })

        if let base64 = payload["artworkData"] as? String,
            let data = Data(base64Encoded: base64)
        {
            artwork = NSImage(data: data)
        } else {
            artwork = nil
        }
    }
}
