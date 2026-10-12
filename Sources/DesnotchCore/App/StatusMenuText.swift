import Foundation

/// Wording for the status-menu mirrors of pill glances (process warnings, battery), kept pure
/// so it is testable. The menu is the keyboard/VoiceOver route to what the hover-driven pill
/// shows, so the text carries the same facts as the pill row.
public enum StatusMenuText {
    public static func battery(_ state: BatteryController.BatteryState) -> String {
        let percent = min(max(state.percent, 0), 100)
        switch state.powerStatus {
        case .charging: return "Battery \(percent)% - charging"
        case .pluggedIn: return "Battery \(percent)% - plugged in"
        case .onBattery: return "Battery \(percent)% - on battery"
        }
    }

    public static func hotProcess(_ process: HotProcess, now: Date = Date()) -> String {
        let name = String(process.name.prefix(40))
        return "\(name) - \(Int(process.cpu))% CPU for \(duration(since: process.since, now: now))"
    }

    static func voiceStateTitle(_ state: VoiceState) -> String {
        VoiceStateWords.menuTitle(for: state)
    }

    static func voiceMenuItems(
        state: VoiceState, pending: ConfirmationRequest?, debugTyping: Bool
    ) -> [VoiceMenuItemSpec] {
        var items = [
            VoiceMenuItemSpec(
                title: "Voice: \(voiceStateTitle(state))",
                isEnabled: false,
                action: nil,
                nonce: nil
            )
        ]
        switch state {
        case .idle:
            items.append(VoiceMenuItemSpec(title: "Talk", isEnabled: true, action: .talk, nonce: nil))
        case .armed, .transcribing, .thinking, .acting:
            items.append(Self.stopAgentItem)
        case .listening:
            items.append(VoiceMenuItemSpec(
                title: "Stop Listening", isEnabled: true, action: .stopListening, nonce: nil
            ))
            items.append(VoiceMenuItemSpec(title: "Cancel", isEnabled: true, action: .cancel, nonce: nil))
            items.append(Self.stopAgentItem)
        case .review:
            items.append(VoiceMenuItemSpec(title: "Cancel", isEnabled: true, action: .cancel, nonce: nil))
            items.append(Self.stopAgentItem)
        case .awaitingApproval:
            if let pending {
                if pending.source == .local {
                    items.append(VoiceMenuItemSpec(
                        title: "Approve: \(pending.summary)",
                        isEnabled: pending.canApprove,
                        action: .approve,
                        nonce: pending.nonce
                    ))
                }
                items.append(VoiceMenuItemSpec(
                    title: "Deny", isEnabled: true, action: .deny, nonce: pending.nonce
                ))
            }
            items.append(Self.stopAgentItem)
        case .speaking, .error:
            items.append(VoiceMenuItemSpec(title: "Talk", isEnabled: true, action: .talk, nonce: nil))
            items.append(Self.stopAgentItem)
        case .paused:
            items.append(VoiceMenuItemSpec(title: "Resume Voice", isEnabled: true, action: .resume, nonce: nil))
        }
        if debugTyping {
            items.append(VoiceMenuItemSpec(
                title: "Type a Voice Command…",
                isEnabled: state == .idle,
                action: .typeCommand,
                nonce: nil
            ))
        }
        return items
    }

    private static var stopAgentItem: VoiceMenuItemSpec {
        VoiceMenuItemSpec(title: "Stop Voice Agent", isEnabled: true, action: .stopAgent, nonce: nil)
    }

    /// "under a minute", "5 min", "2 h".
    static func duration(since: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes == 0 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h"
    }
}

enum VoiceMenuAction: Equatable {
    case talk, stopListening, approve, deny, cancel, stopAgent, resume, typeCommand
}

struct VoiceMenuItemSpec: Equatable {
    var title: String
    var isEnabled: Bool
    var action: VoiceMenuAction?
    var nonce: String?
}

struct VoiceMenuPayload: Equatable {
    let action: VoiceMenuAction
    let nonce: String?
}
