import Foundation

// WP-LOGIC owns this file. Base commit: fail-closed stubs with the final signatures.

enum ConfirmationPolicy {
    /// The tier of a local intent (T0 for everything except volume above the confirm line).
    static func tier(of intent: LocalIntent) -> VoiceTier {
        // STUB (WP-LOGIC replaces this body): fail closed.
        .t4
    }

    /// Tier to gate decision. T0/T1 allow, T2 confirm, T3 denied while no second factor, T4 denied.
    static func decide(tier: VoiceTier, secondFactorAvailable: Bool) -> PolicyDecision {
        // STUB (WP-LOGIC replaces this body): fail closed.
        .deny(.notImplemented)
    }
}

/// Classifies Hermes tool names (category labels) into tiers. Default-deny: an unknown name
/// is T3 and trips the tripwire.
enum ToolTierTable {
    static func tier(forTool kind: String) -> VoiceTier {
        // STUB (WP-LOGIC replaces this body): fail closed.
        .t4
    }
}
