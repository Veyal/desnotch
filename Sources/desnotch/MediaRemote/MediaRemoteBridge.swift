import AppKit
import Foundation

/// Thin Swift wrapper around the private `MediaRemote.framework`.
///
/// There is no public API for reading system-wide now-playing state or for sending
/// play/pause/next/previous commands to whatever app currently owns the "Now Playing"
/// session. NotchNook, Alcove, and most other notch/now-playing utilities all reach
/// into this private framework the same way: `dlopen` the framework bundle, then
/// `dlsym` the handful of C functions and CFString constants they need. Apple could
/// change or remove these symbols in any OS release without notice - that's an
/// accepted tradeoff for a non-App-Store app, not an oversight.
///
/// All of this is looked up lazily and defensively: if the framework or a symbol is
/// missing (sandboxed context, future macOS removing it, etc.) the bridge simply
/// reports no now-playing info instead of crashing.
final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    /// Reverse-engineered `MRMediaRemoteCommand` enum values. These are stable across
    /// the macOS releases this app targets but are not a public/documented contract.
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    var onNowPlayingChange: (() -> Void)?

    private let handle: UnsafeMutableRawPointer?

    private typealias GetNowPlayingInfoFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void
    private typealias RegisterNotificationsFn = @convention(c) (DispatchQueue) -> Void
    private typealias SendCommandFn = @convention(c) (Int, CFDictionary?) -> Bool
    private typealias GetIsPlayingFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private let getNowPlayingInfoFn: GetNowPlayingInfoFn?
    private let registerNotificationsFn: RegisterNotificationsFn?
    private let sendCommandFn: SendCommandFn?
    private let getIsPlayingFn: GetIsPlayingFn?

    private let notificationCenter = CFNotificationCenterGetDistributedCenter()
    private let queue = DispatchQueue(label: "com.desnotch.mediaremote")

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )
        self.handle = handle

        getNowPlayingInfoFn = Self.symbol(handle, "MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfoFn.self)
        registerNotificationsFn = Self.symbol(
            handle, "MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterNotificationsFn.self
        )
        sendCommandFn = Self.symbol(handle, "MRMediaRemoteSendCommand", as: SendCommandFn.self)
        getIsPlayingFn = Self.symbol(
            handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlayingFn.self
        )

        registerForChangeNotifications(name: "kMRMediaRemoteNowPlayingInfoDidChangeNotification")
        registerForChangeNotifications(name: "kMRMediaRemotePlaybackQueueChangedNotification")
        registerForChangeNotifications(name: "kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
        registerForChangeNotifications(name: "kMRMediaRemoteNowPlayingApplicationClientStateDidChange")

        registerNotificationsFn?(queue)
    }

    /// `name` is looked up as a `const CFStringRef` symbol exported by the framework
    /// rather than hardcoded, since the *value* backing these notification-name
    /// constants is not part of any public contract either - only the symbol name is
    /// stable enough to rely on.
    private func registerForChangeNotifications(name: String) {
        guard let handle,
            let symPtr = dlsym(handle, name)
        else { return }
        let cfStringPtr = symPtr.assumingMemoryBound(to: CFString?.self)
        guard let cfString = cfStringPtr.pointee else { return }
        let cfName = CFNotificationName(rawValue: cfString)

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            notificationCenter,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let bridge = Unmanaged<MediaRemoteBridge>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    bridge.onNowPlayingChange?()
                }
            },
            cfName.rawValue,
            nil,
            .deliverImmediately
        )
    }

    func fetchNowPlayingInfo(completion: @escaping (NowPlayingInfo?) -> Void) {
        guard let getNowPlayingInfoFn else {
            completion(nil)
            return
        }
        getNowPlayingInfoFn(queue) { [weak self] cfInfo in
            guard let self, let cfInfo else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let info = NowPlayingInfo(cfDictionary: cfInfo)
            guard let getIsPlayingFn = self.getIsPlayingFn else {
                DispatchQueue.main.async { completion(info) }
                return
            }
            getIsPlayingFn(self.queue) { isPlaying in
                var info = info
                info.isPlaying = isPlaying
                DispatchQueue.main.async { completion(info) }
            }
        }
    }

    func send(_ command: Command) {
        _ = sendCommandFn?(command.rawValue, nil)
    }
}
