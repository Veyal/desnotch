import Foundation

// WP-LOGIC owns this file. The base commit provides the shape (it is embedded in
// `VoiceContext`) and a fail-closed stub: until WP-LOGIC implements `tryConsume`, every call
// is refused.

enum RateVerdict: Equatable, Sendable {
    case allowed
    /// Refused; `retryAfter` seconds until a slot frees up.
    case limited(retryAfter: Double)
}

/// Sliding-window limiter for T1 (10 per 60 s) and T2/T3 (3 per 600 s). T0 is unlimited.
/// A pure value type held inside `VoiceContext`; time is always passed in.
struct RateLimiter: Equatable, Sendable {
    var t1Events: [Date] = []
    var t2Events: [Date] = []

    init() {}

    mutating func tryConsume(tier: VoiceTier, now: Date) -> RateVerdict {
        // STUB (WP-LOGIC replaces this body): fail closed.
        .limited(retryAfter: 60)
    }
}
