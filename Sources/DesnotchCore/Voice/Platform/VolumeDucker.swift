import Foundation

@MainActor
final class VolumeDucker: MediaDucking {
    private let volume: VolumeControlling

    private var originalLevel: Float?
    private var duckedLevel: Float?

    init(volume: VolumeControlling) {
        self.volume = volume
    }

    convenience init() {
        self.init(volume: SystemVolumeControl())
    }

    func duck() {
        guard originalLevel == nil else { return }
        guard let current = volume.current() else { return }
        guard current > 0.15 else { return }

        let target: Float = 0.15
        let delta = target - current
        if let actual = volume.adjust(by: delta) {
            originalLevel = current
            duckedLevel = actual
        }
    }

    func restore() {
        guard let original = originalLevel, let ducked = duckedLevel else {
            originalLevel = nil
            duckedLevel = nil
            return
        }

        if let current = volume.current() {
            if abs(current - ducked) <= 0.02 {
                let delta = original - current
                _ = volume.adjust(by: delta)
            }
        }

        originalLevel = nil
        duckedLevel = nil
    }
}
