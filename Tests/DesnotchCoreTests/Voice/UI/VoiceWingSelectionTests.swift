import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceWingSelectionTests: XCTestCase {
    func testVoiceTakesTheLeftWingForEveryActiveState() {
        let background = busyInputs(voiceState: nil)
        let unchanged = WingSelection.select(background)
        for state in VoiceState.allCases {
            let wings = WingSelection.select(busyInputs(voiceState: state == .idle ? nil : state))
            if state == .idle {
                XCTAssertEqual(wings.left, unchanged.left)
                XCTAssertEqual(wings.right, unchanged.right)
                continue
            }
            XCTAssertEqual(wings.left, .voice, "\(state)")
            if state == .listening || state == .awaitingApproval {
                XCTAssertEqual(wings.right, .voice, "\(state)")
            } else {
                XCTAssertEqual(wings.right, unchanged.right, "\(state)")
            }
        }
    }

    func testVoiceBeatsVolumeOnTheLeft() {
        let wings = WingSelection.select(WingInputs(volumeActive: true, hasMedia: true, voiceState: .armed))
        XCTAssertEqual(wings.left, .voice)
        XCTAssertEqual(wings.right, .volume)
        let listening = WingSelection.select(WingInputs(volumeActive: true, voiceState: .listening))
        XCTAssertEqual(listening.left, .voice)
        XCTAssertEqual(listening.right, .voice)
    }

    func testNilVoiceStateLeavesThreeExistingCombinationsUnchanged() {
        let volume = WingSelection.select(WingInputs(volumeActive: true, voiceState: nil))
        XCTAssertEqual(volume.left, .volume)
        XCTAssertEqual(volume.right, .volume)

        let mediaAndTimer = WingSelection.select(WingInputs(hasMedia: true, hasTimer: true, voiceState: nil))
        XCTAssertEqual(mediaAndTimer.left, .media)
        XCTAssertEqual(mediaAndTimer.right, .timer)

        let agents = WingSelection.select(WingInputs(hasAgents: true, voiceState: nil))
        XCTAssertEqual(agents.left, nil)
        XCTAssertEqual(agents.right, .agent)
    }

    func testVoiceWingMetricsStayInsideTheBaseWing() {
        XCTAssertEqual(
            WingMetrics.contentWidth(of: .voice, timerShowsLabel: true, agentLabelLength: 1),
            16
        )
        XCTAssertEqual(WingMetrics.contentWidth(of: .voice, timerShowsLabel: false, agentLabelLength: 2), 16)
        XCTAssertEqual(WingMetrics.inset(of: .voice), WingMetrics.persistentInset)
        XCTAssertEqual(
            WingMetrics.extraWidth(left: .voice, right: .voice, timerShowsLabel: true, agentLabelLength: 1),
            0
        )
        XCTAssertEqual(VoiceMeter.totalWidth, 16)
        XCTAssertEqual(VoiceMeter.barCount, VoiceLimits.meterBars)
        XCTAssertEqual(VoiceMeter.barWidth, 2)
        XCTAssertEqual(VoiceMeter.barSpacing, 1.5)
        XCTAssertEqual(VoiceMeter.minBarHeight, 3)
        XCTAssertEqual(VoiceMeter.maxBarHeight, 12)
    }

    private func busyInputs(voiceState: VoiceState?) -> WingInputs {
        WingInputs(
            volumeActive: true,
            hasMedia: true,
            hasTimer: true,
            hasAgents: true,
            hasHotProcesses: true,
            hasNotification: true,
            calendarImminent: true,
            reminderUrgent: true,
            voiceState: voiceState
        )
    }
}
