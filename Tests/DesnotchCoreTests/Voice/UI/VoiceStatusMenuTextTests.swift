import XCTest
@testable import DesnotchCore

final class VoiceStatusMenuTextTests: XCTestCase {
    func testVoiceStateTitleCoversEveryState() {
        let expected: [VoiceState: String] = [
            .idle: "Idle",
            .armed: "Starting",
            .listening: "Listening",
            .transcribing: "Transcribing",
            .review: "Confirming",
            .thinking: "Thinking",
            .acting: "Working",
            .awaitingApproval: "Needs Approval",
            .speaking: "Speaking",
            .error: "Error",
            .paused: "Stopped"
        ]
        XCTAssertEqual(VoiceState.allCases.count, expected.count)
        for state in VoiceState.allCases {
            XCTAssertEqual(StatusMenuText.voiceStateTitle(state), expected[state])
            let items = StatusMenuText.voiceMenuItems(state: state, pending: nil, debugTyping: false)
            XCTAssertEqual(items.first?.title, "Voice: \(expected[state] ?? "")")
            XCTAssertEqual(items.first?.isEnabled, false)
            XCTAssertNil(items.first?.action)
        }
    }

    func testItemsForEachState() {
        XCTAssertEqual(actions(for: .idle), [.talk])
        XCTAssertEqual(actions(for: .armed), [.stopAgent])
        XCTAssertEqual(actions(for: .transcribing), [.stopAgent])
        XCTAssertEqual(actions(for: .thinking), [.stopAgent])
        XCTAssertEqual(actions(for: .acting), [.stopAgent])
        XCTAssertEqual(actions(for: .listening), [.stopListening, .cancel, .stopAgent])
        XCTAssertEqual(actions(for: .review), [.cancel, .stopAgent])
        XCTAssertEqual(actions(for: .speaking), [.talk, .stopAgent])
        XCTAssertEqual(actions(for: .error), [.talk, .stopAgent])
        XCTAssertEqual(actions(for: .paused), [.resume])
        XCTAssertEqual(actions(for: .awaitingApproval), [.stopAgent])

        let paused = StatusMenuText.voiceMenuItems(state: .paused, pending: nil, debugTyping: false)
        XCTAssertEqual(paused.last?.title, "Resume Voice")
        XCTAssertEqual(paused.last?.isEnabled, true)
        let listening = StatusMenuText.voiceMenuItems(state: .listening, pending: nil, debugTyping: false)
        XCTAssertEqual(listening.map(\.title), [
            "Voice: Listening", "Stop Listening", "Cancel", "Stop Voice Agent"
        ])
    }

    func testLocalCardOffersApproveAndDeny() {
        let pending = ConfirmationRequest(
            nonce: "local-nonce", tier: .t2, source: .local,
            summary: "Set volume to 90%", literal: "Set volume to 90%"
        )
        let items = StatusMenuText.voiceMenuItems(
            state: .awaitingApproval, pending: pending, debugTyping: false
        )
        XCTAssertEqual(items.map(\.action), [nil, .approve, .deny, .stopAgent])
        XCTAssertEqual(items[1].title, "Approve: Set volume to 90%")
        XCTAssertTrue(items[1].isEnabled)
        XCTAssertEqual(items[1].nonce, "local-nonce")
        XCTAssertEqual(items[2].title, "Deny")
        XCTAssertTrue(items[2].isEnabled)
        XCTAssertEqual(items[2].nonce, "local-nonce")
    }

    func testHermesCardOffersDenyOnly() {
        let pending = ConfirmationRequest(
            nonce: "agent-nonce", tier: .t2, source: .hermes, summary: "Run ls", literal: "ls"
        )
        let items = StatusMenuText.voiceMenuItems(
            state: .awaitingApproval, pending: pending, debugTyping: false
        )
        XCTAssertEqual(items.map(\.action), [nil, .deny, .stopAgent])
        XCTAssertFalse(items.contains { $0.action == .approve })
        XCTAssertEqual(items[1].nonce, "agent-nonce")
        XCTAssertTrue(items[1].isEnabled)
    }

    func testApproveIsDisabledWhenTheCardCannotBeApproved() {
        let pending = ConfirmationRequest(
            nonce: "blocked", tier: .t3, source: .local, summary: "Fetch", literal: "curl"
        )
        XCTAssertFalse(pending.canApprove)
        let items = StatusMenuText.voiceMenuItems(
            state: .awaitingApproval, pending: pending, debugTyping: false
        )
        let approve = items.first { $0.action == .approve }
        XCTAssertEqual(approve?.isEnabled, false)
        XCTAssertEqual(approve?.nonce, "blocked")
        XCTAssertEqual(items.first { $0.action == .deny }?.isEnabled, true)
    }

    func testDebugTypingIsLastAndEnabledOnlyWhileIdle() {
        let idle = StatusMenuText.voiceMenuItems(state: .idle, pending: nil, debugTyping: true)
        XCTAssertEqual(idle.last?.title, "Type a Voice Command…")
        XCTAssertEqual(idle.last?.action, .typeCommand)
        XCTAssertEqual(idle.last?.isEnabled, true)
        let listening = StatusMenuText.voiceMenuItems(state: .listening, pending: nil, debugTyping: true)
        XCTAssertEqual(listening.last?.action, .typeCommand)
        XCTAssertEqual(listening.last?.isEnabled, false)
        let hidden = StatusMenuText.voiceMenuItems(state: .idle, pending: nil, debugTyping: false)
        XCTAssertFalse(hidden.contains { $0.action == .typeCommand })
    }

    private func actions(for state: VoiceState) -> [VoiceMenuAction] {
        StatusMenuText.voiceMenuItems(state: state, pending: nil, debugTyping: false)
            .compactMap(\.action)
    }
}
