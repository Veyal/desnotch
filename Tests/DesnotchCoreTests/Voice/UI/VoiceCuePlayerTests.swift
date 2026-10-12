import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceCuePlayerTests: XCTestCase {
    func testCueMappingTable() {
        let log = CueLog()
        let player = log.player()
        let expected: [(VoiceCue, String?, String?)] = [
            (.captureStart, "Tink", "voiceStart"),
            (.captureEnd, "Pop", nil),
            (.commit, nil, "voiceCommit"),
            (.needsConfirmation, "Ping", "voiceNeedsConfirm"),
            (.approved, "Pop", "voiceApproved"),
            (.done, nil, "voiceCommit"),
            (.error, "Basso", "voiceError")
        ]
        XCTAssertEqual(VoiceCue.allCases.count, expected.count)
        for row in expected {
            log.reset()
            player.play(row.0)
            XCTAssertEqual(log.sounds, row.1.map { [$0] } ?? [], "\(row.0)")
            XCTAssertEqual(log.haptics.map(Self.eventName), row.2.map { [$0] } ?? [], "\(row.0)")
            XCTAssertEqual(log.beeps, 0, "\(row.0)")
        }
    }

    func testMissingErrorSoundBeepsOnce() {
        let log = CueLog()
        log.soundExists = false
        log.player().play(.error)
        XCTAssertEqual(log.sounds, ["Basso"])
        XCTAssertEqual(log.beeps, 1)
        XCTAssertEqual(log.haptics.map(Self.eventName), ["voiceError"])
    }

    func testMissingCaptureStartSoundDoesNotBeep() {
        let log = CueLog()
        log.soundExists = false
        log.player().play(.captureStart)
        XCTAssertEqual(log.sounds, ["Tink"])
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(log.haptics.map(Self.eventName), ["voiceStart"])
    }

    func testCommitDoneAndCaptureEndCallOnlyTheirSide() {
        let log = CueLog()
        let player = log.player()
        player.play(.commit)
        XCTAssertTrue(log.sounds.isEmpty)
        XCTAssertEqual(log.haptics.map(Self.eventName), ["voiceCommit"])
        log.reset()
        player.play(.done)
        XCTAssertTrue(log.sounds.isEmpty)
        XCTAssertEqual(log.haptics.map(Self.eventName), ["voiceCommit"])
        log.reset()
        player.play(.captureEnd)
        XCTAssertEqual(log.sounds, ["Pop"])
        XCTAssertTrue(log.haptics.isEmpty)
        XCTAssertEqual(log.beeps, 0)
    }

    func testParameterlessInitDoesNotPlay() {
        let player = VoiceCuePlayer()
        XCTAssertTrue(type(of: player) == VoiceCuePlayer.self)
    }

    private static func eventName(_ event: PillHaptics.Event) -> String {
        switch event {
        case .voiceStart: return "voiceStart"
        case .voiceCommit: return "voiceCommit"
        case .voiceNeedsConfirm: return "voiceNeedsConfirm"
        case .voiceApproved: return "voiceApproved"
        case .voiceError: return "voiceError"
        default: return "other"
        }
    }

    @MainActor
    private final class CueLog {
        var sounds: [String] = []
        var haptics: [PillHaptics.Event] = []
        var beeps = 0
        var soundExists = true

        func reset() {
            sounds = []
            haptics = []
            beeps = 0
        }

        func player() -> VoiceCuePlayer {
            VoiceCuePlayer(
                playSound: { name in
                    self.sounds.append(name)
                    return self.soundExists
                },
                haptic: { self.haptics.append($0) },
                beep: { self.beeps += 1 }
            )
        }
    }
}
