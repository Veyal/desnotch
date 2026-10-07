import SwiftUI

/// The pill's silhouette: flush with the screen's top edge, a small concave flare ("ear")
/// where the top meets the screen, and rounded bottom corners. The collapsed pill uses the
/// hardware cutout's proportions, so it reads as the notch itself, and the expanded pill is
/// that same silhouette grown (both radii interpolate with the frame on one spring).
/// Custom shape rather than `UnevenRoundedRectangle`, which needs macOS 13.3; the package
/// targets 13.0.
struct NotchShape: Shape {
    /// Concave flare radius at the two top corners.
    var topEar: CGFloat
    /// Convex radius of the two bottom corners.
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topEar, bottomRadius) }
        set {
            topEar = newValue.first
            bottomRadius = newValue.second
        }
    }

    /// Radii after clamping to the rect, so tiny or mid-animation frames never produce a
    /// negative radius, a self-intersecting path, or NaN.
    static func clampedRadii(
        topEar: CGFloat, bottomRadius: CGFloat, in size: CGSize
    ) -> (ear: CGFloat, bottom: CGFloat) {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let ear = max(0, min(topEar.isFinite ? topEar : 0, height / 2, width / 4))
        let bottom = max(
            0,
            min(bottomRadius.isFinite ? bottomRadius : 0, (height - ear) / 2, (width - 2 * ear) / 2)
        )
        return (ear, bottom)
    }

    func path(in rect: CGRect) -> Path {
        let (e, b) = Self.clampedRadii(topEar: topEar, bottomRadius: bottomRadius, in: rect.size)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - e, y: rect.minY + e),
            control: CGPoint(x: rect.maxX - e, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.maxY - b))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - e - b, y: rect.maxY),
            control: CGPoint(x: rect.maxX - e, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + e + b, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + e, y: rect.maxY - b),
            control: CGPoint(x: rect.minX + e, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.minY + e))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: rect.minX + e, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
