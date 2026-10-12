import XCTest
@testable import DesnotchCore

@MainActor
final class VoiceAccessibilityTextTests: XCTestCase {
    func testVoiceCompactLabelForNilAndEveryState() {
        XCTAssertNil(NotchPillView.voiceCompactLabel(nil))
        XCTAssertNil(NotchPillView.voiceCompactLabel(.idle))
        let expected: [VoiceState: String] = [
            .armed: "Voice: starting",
            .listening: "Voice: listening",
            .transcribing: "Voice: transcribing",
            .review: "Voice: confirming",
            .thinking: "Voice: thinking",
            .acting: "Voice: working",
            .awaitingApproval: "Voice: needs approval",
            .speaking: "Voice: speaking",
            .error: "Voice: error",
            .paused: "Voice: stopped"
        ]
        for state in VoiceState.allCases where state != .idle {
            XCTAssertEqual(NotchPillView.voiceCompactLabel(state), expected[state], "\(state)")
        }
    }

    func testAnnouncementStrings() {
        XCTAssertEqual(PillAnnouncements.voiceNeedsApproval, "Voice command needs approval")
        XCTAssertEqual(PillAnnouncements.voiceFailed, "Voice command failed")
        XCTAssertEqual(PillAnnouncements.voiceStopped, "Voice agent stopped")
    }

    func testAnnouncementPolicyForEveryStateAndSeverity() {
        let severities: [VoiceFailure.Severity] = [.info, .warning, .alert]
        for state in VoiceState.allCases {
            for severity in severities {
                let announcement = VoiceAnnouncementPolicy.announcement(for: state, severity: severity)
                switch (state, severity) {
                case (.awaitingApproval, _):
                    XCTAssertEqual(announcement?.message, PillAnnouncements.voiceNeedsApproval)
                    XCTAssertEqual(announcement?.isHighPriority, true)
                case (.error, .warning), (.error, .alert):
                    XCTAssertEqual(announcement?.message, PillAnnouncements.voiceFailed)
                    XCTAssertEqual(announcement?.isHighPriority, false)
                case (.paused, _):
                    XCTAssertEqual(announcement?.message, PillAnnouncements.voiceStopped)
                    XCTAssertEqual(announcement?.isHighPriority, false)
                default:
                    XCTAssertNil(announcement, "\(state) \(severity)")
                }
            }
        }
    }

    func testAnnouncementsNeverContainTranscriptReplyOrLiteral() {
        let secrets = ["SECRET-TRANSCRIPT", "SECRET-REPLY", "SECRET-LITERAL"]
        let phrases = [
            PillAnnouncements.voiceNeedsApproval,
            PillAnnouncements.voiceFailed,
            PillAnnouncements.voiceStopped
        ] + VoiceState.allCases.compactMap { NotchPillView.voiceCompactLabel($0) }
        for phrase in phrases {
            for secret in secrets {
                XCTAssertFalse(phrase.contains(secret), phrase)
            }
        }
        let severities: [VoiceFailure.Severity] = [.info, .warning, .alert]
        for state in VoiceState.allCases {
            for severity in severities {
                guard let message = VoiceAnnouncementPolicy.announcement(for: state, severity: severity)?.message else {
                    continue
                }
                for secret in secrets {
                    XCTAssertFalse(message.contains(secret))
                }
            }
        }
    }
}
