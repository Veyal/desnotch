import AppKit
import Foundation

/// Parsed snapshot of MediaRemote's now-playing dictionary.
///
/// The dictionary keys read here (`kMRMediaRemoteNowPlayingInfoTitle` etc.) are the
/// well-known reverse-engineered key strings MediaRemote fills in - not a public,
/// documented schema. Missing/renamed keys degrade gracefully to `nil`/defaults
/// rather than crashing.
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

    init(cfDictionary: CFDictionary) {
        let dict = cfDictionary as NSDictionary
        title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String
        album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
        uniqueIdentifier = (dict["kMRMediaRemoteNowPlayingInfoUniqueIdentifier"] as? NSObject)?.description

        if let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double {
            isPlaying = rate > 0
        } else {
            isPlaying = false
        }

        if let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            artwork = NSImage(data: artworkData)
        } else {
            artwork = nil
        }
    }
}
