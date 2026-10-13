import XCTest
@testable import DesnotchCore

private let toolT0 = Date(timeIntervalSince1970: 1_800_000_000)

private func toolEnv(nonce: String = "n1") -> VoiceReducerEnv {
    VoiceReducerEnv(now: toolT0, voiceEnabled: true, screenLocked: false, hermesLaneReady: true,
                    hermesTurnsRemainingToday: 40, speechAllowed: false, secondFactorAvailable: false,
                    freshNonce: nonce)
}

private func toolCtx(_ state: VoiceState, _ edit: (inout VoiceContext) -> Void = { _ in }) -> VoiceContext {
    var c = VoiceContext()
    c.state = state
    c.counter = 1
    c.generation = 1
    c.lane = .hermes
    edit(&c)
    return c
}

private func toolStep(_ c: VoiceContext, _ e: VoiceEvent) -> VoiceTransition {
    VoiceReducer.reduce(c, e, env: toolEnv())
}

private func toolCard(_ tier: VoiceTier, nonce: String = "t1", literal: String = "ls ~/Downloads") -> ConfirmationRequest {
    ConfirmationRequest(nonce: nonce, tier: tier, source: .hermes, summary: "Run a shell command", literal: literal,
                        requiresSecondFactor: tier >= .t3)
}

/// The machine-control amendment rules (PLAN section 7, "In-process tools"): R82t, R84t, R85t.
final class VoiceReducerToolRuleTests: XCTestCase {
    func testR82t_inProcessStepLabelsUseTheirTableTier() {
        for (label, tier) in AgentToolStep.tiers {
            XCTAssertEqual(ToolTierTable.tier(forTool: label), tier, label)
        }
        let quiet = toolStep(toolCtx(.thinking), .agent(.toolActivity(kind: AgentToolStep.readFile), generation: 1))
        XCTAssertEqual(quiet.context.state, .acting)
        XCTAssertEqual(quiet.context.steps, [VoiceStep(id: 0, kind: AgentToolStep.readFile)])
        XCTAssertTrue(quiet.effects.isEmpty)
    }

    func testR82t_approvedLabelWithoutAnApprovalTripsTheWire() {
        let t = toolStep(toolCtx(.acting), .agent(.toolActivity(kind: AgentToolStep.runCommandApproved), generation: 1))
        XCTAssertEqual(t.context.state, .paused)
        XCTAssertEqual(t.context.failure, .tripwire(tool: AgentToolStep.runCommandApproved))
        XCTAssertEqual(t.effects.first, .stopAgentHard)
    }

    func testR82t_hermesCannotProduceAnInProcessLabel() {
        for label in AgentToolStep.tiers.keys {
            XCTAssertNotEqual(HermesEventMapper.toolKind(label), label, label)
            XCTAssertNotEqual(HermesEventMapper.toolKind(label + ": x"), label, label)
        }
        XCTAssertEqual(ToolTierTable.tier(forTool: "read file"), .t2, "lowercased lookalikes keep the Hermes table")
        XCTAssertEqual(ToolTierTable.tier(forTool: "run command (approved)"), .t3)
    }

    func testR84t_t3AndT4ProposalsAreAutoDeniedWithoutACard() {
        for tier in [VoiceTier.t3, .t4] {
            let c = toolCtx(.acting)
            let t = toolStep(c, .agent(.approvalNeeded(toolCard(tier)), generation: 1))
            XCTAssertEqual(t.context.state, .acting)
            XCTAssertNil(t.context.pending)
            XCTAssertEqual(t.effects, [
                .respondToApproval(nonce: "t1", allow: false),
                .audit(AuditDraft(kind: .denial, lane: .hermes, tier: tier, decision: "auto_deny"))
            ])
        }
    }

    func testR85t_t2ProposalShowsAHoldCardAndTheApprovedStartConsumesIt() {
        let asked = toolStep(toolCtx(.thinking), .agent(.approvalNeeded(toolCard(.t2)), generation: 1))
        XCTAssertEqual(asked.context.state, .awaitingApproval)
        XCTAssertEqual(asked.context.pending?.literal, "ls ~/Downloads")
        XCTAssertEqual(asked.context.pending?.source, .hermes)
        let approved = toolStep(asked.context, .approveRequested(nonce: "t1"))
        XCTAssertEqual(approved.context.approvedToolStarts, 1)
        XCTAssertEqual(approved.effects.first, .respondToApproval(nonce: "t1", allow: true))
        let started = toolStep(approved.context, .agent(.toolActivity(kind: AgentToolStep.runCommandApproved), generation: 1))
        XCTAssertEqual(started.context.state, .acting)
        XCTAssertEqual(started.context.approvedToolStarts, 0)
        XCTAssertEqual(started.context.steps.last?.kind, AgentToolStep.runCommandApproved)
        let second = toolStep(started.context, .agent(.toolActivity(kind: AgentToolStep.runCommandApproved), generation: 1))
        XCTAssertEqual(second.context.state, .paused, "one approval starts exactly one tool")
    }

    func testR85t_deniedProposalNeverStartsAndTheTurnContinues() {
        let asked = toolStep(toolCtx(.thinking), .agent(.approvalNeeded(toolCard(.t2)), generation: 1))
        let denied = toolStep(asked.context, .denyRequested(nonce: "t1"))
        XCTAssertEqual(denied.context.state, .acting)
        XCTAssertEqual(denied.context.approvedToolStarts, 0)
        XCTAssertEqual(denied.effects.first, .respondToApproval(nonce: "t1", allow: false))
    }
}
