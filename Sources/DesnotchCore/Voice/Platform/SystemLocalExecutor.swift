import AppKit
import Foundation

@MainActor
protocol VolumeControlling: AnyObject {
    func current() -> Float?
    func adjust(by delta: Float) -> Float?
}

@MainActor
protocol MediaTransporting: AnyObject {
    func play()
    func pause()
    func next()
    func previous()
}

@MainActor
protocol TimerControlling: AnyObject {
    var isActive: Bool { get }
    func start(minutes: Int) -> Bool
    func cancel()
}

@MainActor
protocol AppLaunching: AnyObject {
    func launch(bundleID: String) async -> Bool
}

@MainActor
final class SystemVolumeControl: VolumeControlling {
    init() {}

    func current() -> Float? {
        SystemVolume.current()
    }

    func adjust(by delta: Float) -> Float? {
        SystemVolume.adjust(by: delta)
    }
}

@MainActor
final class NowPlayingTransport: MediaTransporting {
    private let controller: NowPlayingController

    init(controller: NowPlayingController) {
        self.controller = controller
    }

    func play() {
        MediaRemoteBridge.shared.send(.play)
    }

    func pause() {
        MediaRemoteBridge.shared.send(.pause)
    }

    func next() {
        controller.next()
    }

    func previous() {
        controller.previous()
    }
}

@MainActor
final class WorkspaceAppLauncher: AppLaunching {
    init() {}

    func launch(bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return true
        } catch {
            return false
        }
    }
}

extension FocusTimerController: TimerControlling {
    public func start(minutes: Int) -> Bool {
        start(duration: TimeInterval(minutes * 60))
    }
}

struct MuteMemory: Equatable, Sendable {
    private var rememberedLevel: Float?

    mutating func mute(current: Float) -> Float? {
        if current > 0.01 {
            if rememberedLevel == nil {
                rememberedLevel = current
            }
            return 0
        } else {
            return nil
        }
    }

    mutating func unmute(current: Float) -> Float? {
        if current <= 0.01 {
            let target = rememberedLevel ?? 0.3
            rememberedLevel = nil
            return target
        } else {
            rememberedLevel = nil
            return nil
        }
    }
}

@MainActor
final class SystemLocalExecutor: LocalExecuting {
    private let volume: VolumeControlling
    private let media: MediaTransporting
    private let timer: TimerControlling
    private let apps: AppLaunching

    private var muteMemory = MuteMemory()

    init(
        volume: VolumeControlling,
        media: MediaTransporting,
        timer: TimerControlling,
        apps: AppLaunching
    ) {
        self.volume = volume
        self.media = media
        self.timer = timer
        self.apps = apps
    }

    convenience init(nowPlaying: NowPlayingController, focusTimer: FocusTimerController) {
        self.init(
            volume: SystemVolumeControl(),
            media: NowPlayingTransport(controller: nowPlaying),
            timer: focusTimer,
            apps: WorkspaceAppLauncher()
        )
    }

    func execute(_ intent: LocalIntent) async -> LocalExecutionResult {
        switch intent {
        case .mediaPlay:
            media.play()
            return .success(spoken: nil)
        case .mediaPause:
            media.pause()
            return .success(spoken: nil)
        case .mediaNext:
            media.next()
            return .success(spoken: nil)
        case .mediaPrevious:
            media.previous()
            return .success(spoken: nil)

        case .volumeSet(let percent):
            let clamped = min(max(percent, 0), 100)
            guard let cur = volume.current() else {
                return .failure(.executionFailed("volume_unavailable"))
            }
            let target = Float(clamped) / 100.0
            let delta = target - cur
            guard volume.adjust(by: delta) != nil else {
                return .failure(.executionFailed("volume_unavailable"))
            }
            return .success(spoken: "Volume \(clamped)")

        case .volumeStep(let delta):
            guard let new = volume.adjust(by: Float(delta) / 100.0) else {
                return .failure(.executionFailed("volume_unavailable"))
            }
            let percent = Int((new * 100).rounded())
            return .success(spoken: "Volume \(percent)")

        case .mute:
            guard let cur = volume.current() else {
                return .failure(.executionFailed("volume_unavailable"))
            }
            if let target = muteMemory.mute(current: cur) {
                guard volume.adjust(by: target - cur) != nil else {
                    return .failure(.executionFailed("volume_unavailable"))
                }
            }
            return .success(spoken: "Muted")

        case .unmute:
            guard let cur = volume.current() else {
                return .failure(.executionFailed("volume_unavailable"))
            }
            if let target = muteMemory.unmute(current: cur) {
                guard volume.adjust(by: target - cur) != nil else {
                    return .failure(.executionFailed("volume_unavailable"))
                }
            }
            return .success(spoken: "Unmuted")

        case .openApp(let bundleID, let name):
            let launched = await apps.launch(bundleID: bundleID)
            if launched {
                return .success(spoken: "Opening \(name)")
            } else {
                return .failure(.executionFailed("app_not_found"))
            }

        case .timerStart(let minutes):
            let started = timer.start(minutes: minutes)
            if started {
                return .success(spoken: "Timer \(minutes) minutes")
            } else {
                return .failure(.executionFailed("timer_unavailable"))
            }

        case .timerCancel:
            if timer.isActive {
                timer.cancel()
                return .success(spoken: "Timer cancelled")
            } else {
                return .success(spoken: "No timer running")
            }
        }
    }
}
