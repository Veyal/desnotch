import Foundation

// WP-LOGIC owns this file. Base commit: fail-closed stub with the final signature.

/// The session state machine as a pure function. No clocks, no I/O, no randomness: time and
/// nonces come in through `VoiceReducerEnv`.
enum VoiceReducer {
    static func reduce(_ context: VoiceContext, _ event: VoiceEvent, env: VoiceReducerEnv) -> VoiceTransition {
        // STUB (WP-LOGIC replaces this body): report that the reducer is not implemented.
        var next = context
        next.state = .error
        next.failure = .unavailable(.notImplemented)
        return VoiceTransition(context: next, effects: [])
    }
}
