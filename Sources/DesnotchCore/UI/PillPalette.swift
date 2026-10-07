import AppKit
import SwiftUI

/// Colors and contrast math for the always-black pill. Everything is measured against
/// pure black (the shape is solid `.black`), so WCAG contrast reduces to a function of the
/// foreground's relative luminance alone: `(L + 0.05) / 0.05`.
enum PillPalette {
    /// Secondary text ("Mist Gray"): 8.1:1 on black. Increase Contrast lifts it.
    static let mistGray = Color(red: 161 / 255, green: 161 / 255, blue: 166 / 255)
    /// Captions and tertiary glyphs ("Slate Gray"): 6.4:1 on black.
    static let slateGray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    /// Secondary/caption text under Increase Contrast ("Silver"): 11.9:1 on black.
    static let silver = Color(red: 199 / 255, green: 199 / 255, blue: 204 / 255)
    /// Neutral tile behind placeholder glyphs ("Surface Control").
    static let surfaceControl = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

    /// An sRGB color given in 0...255 components, so the status palette's contrast on black and
    /// its opaque (Reduce Transparency) tints are checkable in tests rather than eyeballed.
    struct Swatch: Equatable {
        let red: Int
        let green: Int
        let blue: Int

        var color: Color {
            Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        }

        /// WCAG contrast ratio against the pill's pure-black surface.
        var contrastOnBlack: CGFloat {
            PillPalette.contrastOnBlack(
                red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255
            )
        }

        /// The color this swatch becomes at `alpha` over black, as an opaque swatch: the
        /// Reduce Transparency stand-in for `color.opacity(alpha)` on the black shell.
        func opaque(alpha: Double) -> Swatch {
            let a = min(max(alpha, 0), 1)
            func scaled(_ c: Int) -> Int { Int((Double(c) * a).rounded()) }
            return Swatch(red: scaled(red), green: scaled(green), blue: scaled(blue))
        }

        /// A tinted surface fill (chip, well, highlight): translucent normally, the opaque
        /// equivalent under Reduce Transparency.
        func fill(alpha: Double, reduceTransparency: Bool) -> Color {
            reduceTransparency ? opaque(alpha: alpha).color : color.opacity(alpha)
        }
    }

    /// Neutral chip / highlight tint.
    static let white = Swatch(red: 255, green: 255, blue: 255)
    /// Neutral chip text ("Mist Gray" as a swatch): 8.1:1.
    static let mist = Swatch(red: 161, green: 161, blue: 166)
    /// Status colors, each at least 4.5:1 on black. Needs-you / imminent / paused.
    static let amber = Swatch(red: 255, green: 214, blue: 10)
    /// Timer, join, privacy on.
    static let cyan = Swatch(red: 100, green: 210, blue: 255)
    /// Stalled, hot process, microphone dot.
    static let orange = Swatch(red: 255, green: 159, blue: 10)
    /// Charging, complete, camera dot.
    static let green = Swatch(red: 48, green: 209, blue: 88)
    /// Low battery.
    static let red = Swatch(red: 255, green: 69, blue: 58)

    /// Opaque stand-ins for `white.opacity(x)` on black (Reduce Transparency), by gray level.
    static func opaqueWhite(_ alpha: Double) -> Color {
        Color(white: min(max(alpha, 0), 1))
    }

    /// Secondary text color, honoring Increase Contrast.
    static func secondaryText(increasedContrast: Bool) -> Color {
        increasedContrast ? silver : mistGray
    }

    /// Caption / header text color: Slate Gray, lifted to Silver under Increase Contrast.
    static func captionText(increasedContrast: Bool) -> Color {
        increasedContrast ? silver : slateGray
    }

    /// Gray level (0...1, opaque) of the seek bar's unfilled track: 3.4:1 on black (3:1 is the
    /// non-text floor; `white 0.18` was only 1.5:1), 5.3:1 under Increase Contrast. Opaque, so
    /// Reduce Transparency needs no separate stand-in.
    static func seekTrackLevel(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.5 : 0.38
    }

    static func seekTrack(increasedContrast: Bool) -> Color {
        Color(white: seekTrackLevel(increasedContrast: increasedContrast))
    }

    /// Hairline around album art so near-black covers keep a visible silhouette on the black
    /// pill (invisible on bright covers, which define their own edge): `white 0.10` was lost
    /// against dark art. Stronger under Increase Contrast.
    static func artworkEdge(increasedContrast: Bool) -> Color {
        Color.white.opacity(increasedContrast ? 0.36 : 0.22)
    }

    /// WCAG relative luminance of an sRGB color (components 0...1).
    static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            let c = min(max(component, 0), 1)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Contrast ratio of a color against pure black.
    static func contrastOnBlack(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        (relativeLuminance(red: red, green: green, blue: blue) + 0.05) / 0.05
    }

    /// Luminance that yields 4.6:1 on black, just over WCAG AA for text (4.5:1).
    static let aaLuminanceOnBlack: CGFloat = 0.18
    /// Luminance used when Increase Contrast is on.
    static let increasedContrastLuminanceOnBlack: CGFloat = 0.25

    /// Mixes white into a color in 8% steps (at most six) until its luminance reaches
    /// `minLuminance`, so a vivid-but-dark hue stays legible on black while keeping its
    /// character. Colors that are already bright enough are returned unchanged.
    static func lift(
        red: CGFloat, green: CGFloat, blue: CGFloat,
        toMinLuminance minLuminance: CGFloat = aaLuminanceOnBlack
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var color = (red: red, green: green, blue: blue)
        for _ in 0..<6 {
            if relativeLuminance(red: color.red, green: color.green, blue: color.blue) >= minLuminance {
                break
            }
            color = (
                red: color.red + (1 - color.red) * 0.08,
                green: color.green + (1 - color.green) * 0.08,
                blue: color.blue + (1 - color.blue) * 0.08
            )
        }
        return color
    }

    /// `lift` for an `NSColor` (converted to sRGB first); returns the input if it cannot be
    /// converted.
    static func lift(_ color: NSColor, toMinLuminance minLuminance: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        let lifted = lift(
            red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent,
            toMinLuminance: minLuminance
        )
        return NSColor(srgbRed: lifted.red, green: lifted.green, blue: lifted.blue, alpha: rgb.alphaComponent)
    }
}
