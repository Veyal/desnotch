import Foundation

// WP-LOGIC owns this file. Base commit: fail-closed stub with the final signature.

/// Maps one final transcript to a `RouteDecision`. Pure: same input, same output.
enum IntentRouter {
    static func route(_ utterance: String, context: RouterContext) -> RouteDecision {
        // STUB (WP-LOGIC replaces this body): reject everything.
        .reject(.notImplemented)
    }
}
