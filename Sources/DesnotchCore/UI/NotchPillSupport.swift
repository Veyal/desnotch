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

/// The pill's single motion vocabulary. Every animation in the pill resolves through
/// here so the feel stays consistent and one switch (`AnimationStyle`, or the system's
/// Reduce Motion) governs all of it.
///
/// Design intent, Dynamic-Island-like rather than showy: the shape springs only on
/// meaningful *events* (expand/collapse, a section appearing, a banner arriving);
/// everything else is a short opacity crossfade. Nothing loops continuously unless the
/// user opted into it, and Reduce Motion collapses the whole vocabulary to plain fades.
enum NotchAnimation {
    struct Motion: Equatable {
        /// Shape growth, section insertion/removal - the "event" spring.
        let primary: Animation
        /// Small state crossfades (indicator swaps, dots, volume readout).
        let secondary: Animation
        /// Whether perpetual motion (the equalizer) may run at all.
        let allowsLooping: Bool
        /// Whether one-shot symbol pulses (needs-you bounce) may fire.
        let allowsPulse: Bool
        /// Scale an arriving row grows from; 1 means "no scale, fade only".
        let arrivalScale: CGFloat
        /// Whether arriving rows also slide in from the top edge.
        let arrivalSlides: Bool

        /// Feedback used while a pill control is held down. Keeping this here makes
        /// direct manipulation feel like the rest of the pill, rather than like a
        /// separate button animation.
        let press: Animation
        /// Geometric squeeze for a pressed control. Reduce Motion resolves this to 1.
        let pressScale: CGFloat
        /// Content choreography used after the container has expanded.
        let expansionContent: Animation
        /// Starting opacity for content revealed during expansion.
        let expansionContentOpacity: Double
        /// Starting scale for content revealed during expansion.
        let expansionContentScale: CGFloat
        /// Starting vertical offset for content revealed during expansion.
        let expansionContentOffset: CGFloat
        /// Cadence for client-side progress readouts. This is not a polling interval.
        let progressMinimumInterval: TimeInterval
        /// Cadence for the opt-in equalizer loop.
        let equalizerMinimumInterval: TimeInterval

        /// Whether size/position-based emphasis (press scale, scrub-knob growth,
        /// row slides) may be used at all. Reduce Motion's central complaint is
        /// geometric movement, so under Minimal/Reduce Motion feedback must be
        /// carried by opacity instead - never by moving or resizing things.
        var allowsGeometry: Bool {
            arrivalSlides || arrivalScale != 1 || pressScale != 1
                || expansionContentScale != 1 || expansionContentOffset != 0
        }
    }

    /// Semantic motion events. Views should choose an event first and let the policy
    /// resolve it; this prevents simultaneous state changes from accidentally stacking
    /// unrelated SwiftUI animations.
    enum Event: Int, CaseIterable, Hashable {
        case pollingRefresh
        case contentReplacement
        case feedback
        case structuralInsertion
        case directManipulation
        case expansion
    }

    enum Channel: Equatable {
        case none, secondary, primary, press
    }

    struct Policy: Equatable {
        let event: Event
        let channel: Channel
        let allowsGeometry: Bool
        let allowsPulse: Bool
    }

    /// Resolves a simultaneous group to one deterministic animation channel. Expansion
    /// owns container geometry, followed by direct manipulation, structural insertion,
    /// feedback, content replacement, and finally polling (which is intentionally inert).
    static func policy(for events: Set<Event>, motion: Motion) -> Policy {
        let event = events.max { $0.rawValue < $1.rawValue } ?? .pollingRefresh
        switch event {
        case .expansion:
            return Policy(event: event, channel: .primary,
                          allowsGeometry: motion.allowsGeometry, allowsPulse: false)
        case .directManipulation:
            return Policy(event: event, channel: .press,
                          allowsGeometry: motion.allowsGeometry, allowsPulse: false)
        case .structuralInsertion:
            return Policy(event: event, channel: .primary,
                          allowsGeometry: motion.allowsGeometry, allowsPulse: motion.allowsPulse)
        case .feedback:
            return Policy(event: event, channel: .secondary,
                          allowsGeometry: false, allowsPulse: motion.allowsPulse)
        case .contentReplacement:
            return Policy(event: event, channel: .secondary,
                          allowsGeometry: false, allowsPulse: false)
        case .pollingRefresh:
            return Policy(event: event, channel: .none,
                          allowsGeometry: false, allowsPulse: false)
        }
    }

    /// Reduce Motion always wins: it maps to exactly the `.minimal` vocabulary,
    /// regardless of the user's style choice.
    static func resolve(style: AnimationStyle, reduceMotion: Bool) -> Motion {
        guard !reduceMotion, style != .minimal else {
            return Motion(
                primary: .easeInOut(duration: 0.18),
                secondary: .easeInOut(duration: 0.12),
                allowsLooping: false,
                allowsPulse: false,
                arrivalScale: 1,
                arrivalSlides: false,
                press: .easeInOut(duration: 0.12),
                pressScale: 1,
                expansionContent: .easeInOut(duration: 0.12),
                expansionContentOpacity: 0,
                expansionContentScale: 1,
                expansionContentOffset: 0,
                progressMinimumInterval: 1,
                equalizerMinimumInterval: 1
            )
        }
        switch style {
        case .dynamic:
            return Motion(
                primary: .spring(response: 0.52, dampingFraction: 0.74),
                secondary: .easeInOut(duration: 0.22),
                allowsLooping: true,
                allowsPulse: true,
                arrivalScale: 0.90,
                arrivalSlides: true,
                press: .spring(response: 0.20, dampingFraction: 0.60),
                pressScale: 0.90,
                expansionContent: .easeOut(duration: 0.24),
                expansionContentOpacity: 0,
                expansionContentScale: 0.96,
                expansionContentOffset: 5,
                progressMinimumInterval: 1,
                equalizerMinimumInterval: 1.0 / 15.0
            )
        case .subtle, .minimal:
            // Tighter and better damped than `.dynamic` - it settles without
            // overshoot you can read, which is what makes it feel built-in.
            return Motion(
                primary: .spring(response: 0.42, dampingFraction: 0.86),
                secondary: .easeInOut(duration: 0.18),
                allowsLooping: true,
                allowsPulse: true,
                arrivalScale: 0.96,
                arrivalSlides: true,
                press: .spring(response: 0.24, dampingFraction: 0.72),
                pressScale: 0.96,
                expansionContent: .easeOut(duration: 0.20),
                expansionContentOpacity: 0,
                expansionContentScale: 0.985,
                expansionContentOffset: 3,
                progressMinimumInterval: 1,
                equalizerMinimumInterval: 1.0 / 15.0
            )
        }
    }
}

/// Decides which minimized music indicator actually renders for a given style +
/// state. Pure so the fallback rules are testable: album art needs artwork AND
/// privacy mode off (art identifies the track on a permanently visible surface);
/// the equalizer needs actual playback AND motion allowed; everything else is the
/// static note. Keep every new style's fallback chain in here, not in the view.
enum MusicIndicatorResolver {
    enum Resolved {
        case equalizer, note, art
    }

    /// `allowsLooping` comes from `NotchAnimation.Motion` - it already folds in both
    /// Reduce Motion and the Minimal style, so the equalizer (the only perpetual
    /// motion in the app) can never run when motion is suppressed.
    static func resolve(
        style: MusicIndicatorStyle,
        hasArtwork: Bool,
        isPlaying: Bool,
        allowsLooping: Bool,
        privacyMode: Bool
    ) -> Resolved {
        if style == .albumArt && hasArtwork && !privacyMode { return .art }
        if style == .note { return .note }
        // .equalizer, and .albumArt's no-art/privacy fallback.
        return (isPlaying && allowsLooping) ? .equalizer : .note
    }
}

/// Tiny three-bar "equalizer" for the minimized wing while media is actually playing -
/// the classic now-playing affordance. Bar heights are a pure function of absolute time
/// (`barLevel`, tested), sampled by a `TimelineView` at the resolved 15fps cadence - so there is no
/// `repeatForever` @State animation to leak or restart, and the timeline exists only
/// while the view is rendered: paused/absent media costs literally nothing. Fixed
/// 12×12 frame so swapping with the static `music.note` never shifts layout.
struct NowPlayingEqualizer: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        let motion = NotchAnimation.resolve(
            style: settings.animationStyle,
            reduceMotion: reduceMotion
        )
        TimelineView(.animation(minimumInterval: motion.equalizerMinimumInterval)) { context in
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

/// Press feedback for pill buttons. The dim is unconditional - a button must always
/// acknowledge a press - but the squeeze is geometric, so it's dropped under
/// Minimal/Reduce Motion. Wrapped in a `View` because a `ButtonStyle` can't hold
/// `@Environment`/`@ObservedObject` itself.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressFeedback(configuration: configuration)
    }

    private struct PressFeedback: View {
        let configuration: ButtonStyleConfiguration
        @ObservedObject private var settings = SettingsStore.shared
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let motion = NotchAnimation.resolve(
                style: settings.animationStyle, reduceMotion: reduceMotion
            )
            configuration.label
                .opacity(configuration.isPressed ? 0.55 : 1)
                .scaleEffect(motion.allowsGeometry && configuration.isPressed ? motion.pressScale : 1)
                .animation(motion.press, value: configuration.isPressed)
        }
    }
}

extension View {
    /// `.contentTransition(.symbolEffect(.replace))` is macOS 14+; fall back to no
    /// transition on macOS 13 so the play/pause swap still builds for the 13 min target.
    @ViewBuilder
    func availabilityGuardedSymbolReplace(enabled: Bool = true) -> some View {
        if #available(macOS 14.0, *), enabled {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// `.symbolEffect(.bounce)` is macOS 14+; on 13 the icon change simply doesn't
    /// pulse. `enabled` is the motion vocabulary's `allowsPulse`, so Reduce Motion and
    /// the Minimal style silence the pulse instead of it firing regardless (it used to).
    @ViewBuilder
    func availabilityGuardedBounce(trigger: Int, enabled: Bool = true) -> some View {
        if #available(macOS 14.0, *), enabled {
            symbolEffect(.bounce, value: trigger)
        } else {
            self
        }
    }
}
