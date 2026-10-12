import AppKit

/// Earcon and haptic for a voice cue. Constructing the player loads nothing: each sound
/// is created on the first play of its cue and kept, so a launch with voice off stays silent.
@MainActor
final class VoiceCuePlayer: VoiceCuePlaying {
    private let playSound: @MainActor (String) -> Bool
    private let haptic: @MainActor (PillHaptics.Event) -> Void
    private let beep: @MainActor () -> Void

    init(
        playSound: @escaping @MainActor (String) -> Bool,
        haptic: @escaping @MainActor (PillHaptics.Event) -> Void,
        beep: @escaping @MainActor () -> Void
    ) {
        self.playSound = playSound
        self.haptic = haptic
        self.beep = beep
    }

    convenience init() {
        let cache = VoiceSoundCache()
        self.init(
            playSound: { name in cache.play(name) },
            haptic: { event in PillHaptics.play(event) },
            beep: { NSSound.beep() }
        )
    }

    func play(_ cue: VoiceCue) {
        if let name = Self.soundName(for: cue) {
            let played = playSound(name)
            if !played && cue == .error {
                beep()
            }
        }
        if let event = Self.hapticEvent(for: cue) {
            haptic(event)
        }
    }

    private static func soundName(for cue: VoiceCue) -> String? {
        switch cue {
        case .captureStart: return "Tink"
        case .captureEnd, .approved: return "Pop"
        case .needsConfirmation: return "Ping"
        case .error: return "Basso"
        case .commit, .done: return nil
        }
    }

    private static func hapticEvent(for cue: VoiceCue) -> PillHaptics.Event? {
        switch cue {
        case .captureStart: return .voiceStart
        case .commit, .done: return .voiceCommit
        case .needsConfirmation: return .voiceNeedsConfirm
        case .approved: return .voiceApproved
        case .error: return .voiceError
        case .captureEnd: return nil
        }
    }
}

/// One cache for named sounds. A sound that is still playing counts as success so a second
/// cue of the same name does not fall through to the system beep.
@MainActor
private final class VoiceSoundCache {
    private var sounds: [String: NSSound] = [:]

    func play(_ name: String) -> Bool {
        let sound: NSSound
        if let cached = sounds[name] {
            sound = cached
        } else if let created = NSSound(named: NSSound.Name(name)) {
            sounds[name] = created
            sound = created
        } else {
            return false
        }
        if sound.isPlaying { return true }
        return sound.play()
    }
}
