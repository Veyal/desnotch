import Foundation

enum LevelMeter {
    /// Maps a linear RMS (0...1, can exceed slightly) to 0...1: dBFS -50...0 mapped linearly, clamped.
    static func level(fromRMS rms: Float) -> Float {
        if rms.isNaN || rms <= 0 {
            return 0
        }
        let db = 20 * log10(rms)
        let mapped = (db + 50) / 50
        return min(max(mapped, 0), 1)
    }

    /// 5 bar heights (0...1) from the last up-to-5 levels, oldest first, padded with 0 on the left.
    static func bars(from history: [Float]) -> [Float] {
        let maxBars = VoiceLimits.meterBars
        let slice = history.suffix(maxBars)
        let paddingCount = max(0, maxBars - slice.count)
        var result = Array(repeating: Float(0), count: paddingCount)
        result.append(contentsOf: slice.map { min(max($0, 0), 1) })
        return result
    }
}

struct EmitThrottle: Sendable {
    private let minInterval: TimeInterval
    private var lastEmit: TimeInterval?

    init(maxHz: Double) {
        self.minInterval = maxHz > 0 ? (1.0 / maxHz) : 0
        self.lastEmit = nil
    }

    mutating func shouldEmit(at time: TimeInterval) -> Bool {
        guard let last = lastEmit else {
            lastEmit = time
            return true
        }
        if time < last {
            return false
        }
        if time - last >= minInterval {
            lastEmit = time
            return true
        }
        return false
    }
}
