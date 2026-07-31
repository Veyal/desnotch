import SwiftUI

/// Rectangle with only the bottom two corners rounded - flush with the screen's top edge,
/// so the pill reads as an extension of the physical notch. (Custom shape rather than
/// `UnevenRoundedRectangle`, which needs macOS 13.3; the package targets 13.0.)
struct BottomRoundedRectangle: Shape {
    var radius: CGFloat

    /// Animate radius changes so the minimized→expanded morph doesn't snap corners.
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// Tiny three-bar "equalizer" for the minimized wing while media is actually playing -
/// the classic now-playing affordance. Bar heights are a pure function of absolute time
/// (`barLevel`, tested), sampled by a `TimelineView` at 20fps - so there is no
/// `repeatForever` @State animation to leak or restart, and the timeline exists only
/// while the view is rendered: paused/absent media costs literally nothing. Fixed
/// 12×12 frame so swapping with the static `music.note` never shifts layout.
struct NowPlayingEqualizer: View {
    static let barCount = 3
    /// Distinct sub-2Hz frequencies and spread phases per bar so the motion reads
    /// organic rather than mechanical, without any randomness (deterministic in time).
    private static let frequencies: [Double] = [1.2, 1.7, 0.9]
    private static let phases: [Double] = [0, 2.1, 4.2]

    /// Normalized 0...1 level of one bar at absolute time `t`.
    static func barLevel(_ index: Int, at t: TimeInterval) -> Double {
        let i = index % barCount
        return 0.5 + 0.5 * sin(2 * .pi * frequencies[i] * t + phases[i])
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    Capsule(style: .continuous)
                        .frame(width: 2.5, height: 3 + 8 * Self.barLevel(i, at: t))
                }
            }
        }
        .frame(width: 12, height: 12, alignment: .bottom)
    }
}

/// Press + hover feedback for pill buttons.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension View {
    /// `.contentTransition(.symbolEffect(.replace))` is macOS 14+; fall back to no
    /// transition on macOS 13 so the play/pause swap still builds for the 13 min target.
    @ViewBuilder
    func availabilityGuardedSymbolReplace() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// `.symbolEffect(.bounce)` is macOS 14+; on 13 the icon change simply doesn't pulse.
    @ViewBuilder
    func availabilityGuardedBounce(trigger: Int) -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.bounce, value: trigger)
        } else {
            self
        }
    }
}
