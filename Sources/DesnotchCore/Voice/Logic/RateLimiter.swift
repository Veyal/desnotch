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
        switch tier {
        case .t0, .t4:
            return .allowed
        case .t1:
            return Self.consume(&t1Events, window: 60, limit: VoiceLimits.t1PerMinute, now: now)
        case .t2, .t3:
            return Self.consume(&t2Events, window: 600, limit: VoiceLimits.t2PerTenMinutes, now: now)
        }
    }

    /// Prunes expired events first, then refuses or records. An event exactly one window old
    /// is expired. `events.min()` is safe because the count reached `limit >= 1`.
    private static func consume(_ events: inout [Date], window: TimeInterval, limit: Int,
                                now: Date) -> RateVerdict {
        events.removeAll { now.timeIntervalSince($0) >= window }
        if events.count >= limit {
            let oldest = events.min() ?? now
            return .limited(retryAfter: oldest.addingTimeInterval(window).timeIntervalSince(now))
        }
        events.append(now)
        return .allowed
    }
}
