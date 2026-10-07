import AppKit
import CoreGraphics

/// Derives one accent color from album artwork: the dominant vivid hue, lifted so it is
/// legible on the pill's black surface. Used for the progress fill, scrub knob, equalizer
/// bars and the soft glow behind the now-playing row.
///
/// Cheap by construction: the artwork is drawn into a 16x16 bitmap once (the caller caches
/// the result per artwork bytes, see `ArtworkCache`), so there is no per-frame work and the
/// whole thing is safe to run on the adapter queue.
enum ArtworkAccent {
    /// Edge length of the sampling bitmap.
    static let sampleSize = 16
    private static let hueBuckets = 12
    /// Below this total weight (sum of saturation^2 * brightness over usable pixels) the
    /// artwork is effectively grayscale and has no meaningful accent.
    static let minimumTotalWeight: Double = 0.8

    /// Dominant vivid color of `image`, or nil for grayscale/very dark/transparent artwork
    /// (callers then fall back to white).
    static func accent(
        from image: CGImage,
        minLuminance: CGFloat = PillPalette.aaLuminanceOnBlack
    ) -> NSColor? {
        let size = sampleSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress,
                    width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        return accent(fromRGBA: pixels, minLuminance: minLuminance)
    }

    /// Pure core on a premultiplied RGBA8 buffer, so the algorithm is testable without
    /// CoreGraphics. Pixels with alpha < 0.5, brightness < 0.18 or saturation < 0.12 are
    /// ignored; the rest vote into 12 hue buckets weighted by `saturation^2 * brightness`.
    static func accent(
        fromRGBA pixels: [UInt8],
        minLuminance: CGFloat = PillPalette.aaLuminanceOnBlack
    ) -> NSColor? {
        var bucketWeight = [Double](repeating: 0, count: hueBuckets)
        var sinSum = [Double](repeating: 0, count: hueBuckets)
        var cosSum = [Double](repeating: 0, count: hueBuckets)
        var satSum = [Double](repeating: 0, count: hueBuckets)
        var briSum = [Double](repeating: 0, count: hueBuckets)
        var total = 0.0

        var index = 0
        while index + 3 < pixels.count {
            defer { index += 4 }
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha >= 0.5 else { continue }
            let r = min(1, Double(pixels[index]) / 255 / alpha)
            let g = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[index + 2]) / 255 / alpha)
            let (hue, saturation, brightness) = hsb(red: r, green: g, blue: b)
            guard brightness >= 0.18, saturation >= 0.12 else { continue }

            let weight = saturation * saturation * brightness
            let bucket = min(hueBuckets - 1, Int(hue * Double(hueBuckets)))
            bucketWeight[bucket] += weight
            sinSum[bucket] += weight * sin(hue * 2 * .pi)
            cosSum[bucket] += weight * cos(hue * 2 * .pi)
            satSum[bucket] += weight * saturation
            briSum[bucket] += weight * brightness
            total += weight
        }

        guard total >= minimumTotalWeight,
              let winner = bucketWeight.indices.max(by: { bucketWeight[$0] < bucketWeight[$1] }),
              bucketWeight[winner] > 0
        else { return nil }

        var hue = atan2(sinSum[winner], cosSum[winner]) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let weight = bucketWeight[winner]
        let saturation = min(max(satSum[winner] / weight, 0.45), 0.85)
        let brightness = min(max(briSum[winner] / weight, 0.82), 1.0)

        let rgb = rgb(hue: hue, saturation: saturation, brightness: brightness)
        let lifted = PillPalette.lift(
            red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue),
            toMinLuminance: minLuminance
        )
        return NSColor(srgbRed: lifted.red, green: lifted.green, blue: lifted.blue, alpha: 1)
    }

    /// Stable, comparable identity of an accent (for change detection and crossfades).
    static func key(for color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return "none" }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(
            format: "%02x%02x%02x",
            byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent)
        )
    }

    // MARK: Color math

    /// Hue in 0..<1, saturation and brightness in 0...1.
    static func hsb(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let delta = maxC - minC
        let brightness = maxC
        let saturation = maxC == 0 ? 0 : delta / maxC
        guard delta > 0 else { return (0, saturation, brightness) }
        var hue: Double
        if maxC == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (min(hue, 0.999_999), saturation, brightness)
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> (red: Double, green: Double, blue: Double) {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - f * saturation)
        let t = brightness * (1 - (1 - f) * saturation)
        switch sector {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}
