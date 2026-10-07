import SwiftUI

/// The visual container and its content deliberately do not switch at the same instant.
/// Expansion grows the black notch first, then reveals content; collapse fades content
/// first, then lets the container settle back into the hardware. Keeping this semantic
/// phase separate from the hover source also makes rapid re-entry interruptible: the
/// newest phase always retargets the same shape instead of queuing another animation.
enum PillExpansionPhase: Equatable {
    case collapsed
    case expanding
    case expanded
    case collapsing

    var keepsExpandedContainer: Bool { self != .collapsed }
}

/// Decides which minimized music indicator actually renders for a given style +
/// state. Pure so the fallback rules are testable: album art needs artwork AND
/// privacy mode off (art identifies the track on a permanently visible surface);
/// the equalizer needs actual playback AND motion allowed; everything else is the
/// static note. Keep every new style's fallback chain in here, not in the view.
enum MusicIndicatorResolver {
    enum Resolved: Equatable {
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

/// "Equalizer" bars while media is actually playing - the classic now-playing affordance.
/// Bar heights are a pure function of absolute time (`barLevel`, tested), sampled by a
/// `TimelineView` at the resolved 15fps cadence - so there is no `repeatForever` @State
/// animation to leak or restart, and the timeline exists only while the view is rendered:
/// paused/absent media costs literally nothing. Callers also pass `paused` so the timeline
/// stops whenever the bars are not on screen (the expanded variant only runs while the pill
/// is fully expanded). The minimized wing uses three 3pt bars in a 14pt slot; the expanded
/// artwork overlay uses four.
struct NowPlayingEqualizer: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bars in the compact (wing) variant.
    static let barCount = 3
    /// Bars in the expanded artwork overlay.
    static let expandedBarCount = 4
    /// Distinct sub-2Hz frequencies and spread phases per bar so the motion reads
    /// organic rather than mechanical, without any randomness (deterministic in time).
    private static let frequencies: [Double] = [1.2, 1.7, 0.9, 1.45]
    private static let phases: [Double] = [0, 2.1, 4.2, 1.0]

    var bars = NowPlayingEqualizer.barCount
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var minHeight: CGFloat = 3
    var maxHeight: CGFloat = 14
    var tint: Color = .white
    var paused = false

    /// Normalized 0...1 level of one bar at absolute time `t`.
    static func barLevel(_ index: Int, at t: TimeInterval) -> Double {
        let i = ((index % frequencies.count) + frequencies.count) % frequencies.count
        return 0.5 + 0.5 * sin(2 * .pi * frequencies[i] * t + phases[i])
    }

    var body: some View {
        let motion = NotchAnimation.resolve(
            style: settings.animationStyle,
            reduceMotion: reduceMotion
        )
        TimelineView(.animation(minimumInterval: motion.equalizerMinimumInterval, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: barWidth, height: minHeight + (maxHeight - minHeight) * Self.barLevel(i, at: t))
                }
            }
        }
        .frame(
            width: CGFloat(bars) * barWidth + CGFloat(max(0, bars - 1)) * spacing,
            height: maxHeight,
            alignment: .bottom
        )
        .accessibilityHidden(true)
    }
}

/// Press feedback for pill buttons, shared by every section so a press always feels the same.
/// Two roles, because a 268pt row must not squeeze like a 24pt icon:
/// - `.icon` (default): a quick spring squeeze + dim on press, a springy release that
///   overshoots slightly (tactile). The squeeze is geometric, so it is dropped under
///   Minimal/Reduce Motion; the dim stays, since a button must always acknowledge a press.
/// - `.row`: a rounded highlight fades in behind the whole row (no squeeze, only a hair of
///   one in the Lively style). Under Reduce Transparency the highlight is an opaque gray.
/// Both draw a visible keyboard-focus ring. Wrapped in a `View` because a `ButtonStyle`
/// can't hold `@Environment`/`@ObservedObject` itself.
struct PillButtonStyle: ButtonStyle {
    enum Role { case icon, row }

    var role: Role = .icon

    func makeBody(configuration: Configuration) -> some View {
        PressFeedback(configuration: configuration, role: role)
    }

    private struct PressFeedback: View {
        let configuration: ButtonStyleConfiguration
        let role: Role
        @ObservedObject private var settings = SettingsStore.shared
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast

        private static let highlightHorizontalBleed: CGFloat = -6
        private static let highlightVerticalBleed: CGFloat = -2

        var body: some View {
            let motion = NotchAnimation.resolve(
                style: settings.animationStyle, reduceMotion: reduceMotion
            )
            let pressed = configuration.isPressed
            switch role {
            case .icon:
                configuration.label
                    .opacity(pressed ? 0.55 : 1)
                    .scaleEffect(motion.allowsGeometry && pressed ? motion.pressScale : 1)
                    .animation(pressed ? motion.press : motion.release, value: pressed)
                    // Visible keyboard focus: the system ring is lost with a custom style on
                    // the black pill, so draw one only while the button holds keyboard focus.
                    .pillFocusRing(
                        RoundedRectangle(cornerRadius: PillRadius.control, style: .continuous),
                        isFocused: isFocused, increasedContrast: contrast == .increased
                    )
            case .row:
                configuration.label
                    .background(
                        RoundedRectangle(cornerRadius: PillRadius.row, style: .continuous)
                            .fill(PillSurface.highlight(
                                base: reduceTransparency ? 0.10 : 0.08,
                                reduceTransparency: reduceTransparency,
                                increasedContrast: contrast == .increased
                            ))
                            .padding(.horizontal, Self.highlightHorizontalBleed)
                            .padding(.vertical, Self.highlightVerticalBleed)
                            .opacity(pressed ? 1 : 0)
                    )
                    .scaleEffect(motion.allowsGeometry && pressed ? motion.rowPressScale : 1)
                    .animation(pressed ? motion.press : motion.release, value: pressed)
                    .pillFocusRing(
                        RoundedRectangle(cornerRadius: PillRadius.row, style: .continuous),
                        isFocused: isFocused, increasedContrast: contrast == .increased,
                        horizontalBleed: Self.highlightHorizontalBleed,
                        verticalBleed: Self.highlightVerticalBleed
                    )
            }
        }
    }
}

/// Icon-only button content with a guaranteed minimum hit target (24x24, scaled with the
/// user's text size) and a full-rectangle `contentShape`, so small glyphs stay easy to click.
/// Use as the label of a `Button` styled with `PillButtonStyle`.
struct PillIconLabel: View {
    let systemName: String
    var size: CGFloat = 11
    var weight: Font.Weight = .medium
    var color: Color = .white
    /// The button sits at the trailing edge of its row or header: pull the 24pt box out by
    /// the glyph's slack so the visible glyph ends flush with the content edge shared by
    /// badges, chips and percent labels (the extra hit area stays inside the pill's inset).
    var alignsTrailing = false

    @ScaledMetric(relativeTo: .body) private var minimumSide: CGFloat = 24

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .frame(minWidth: minimumSide, minHeight: minimumSide)
            .contentShape(Rectangle())
            .padding(.trailing, alignsTrailing ? -Self.trailingSlack(side: minimumSide, glyph: size) : 0)
    }

    /// Empty space between a glyph of about `glyph` points and the right edge of a centered
    /// `side`-point box.
    static func trailingSlack(side: CGFloat, glyph: CGFloat) -> CGFloat {
        max(0, (side - glyph) / 2)
    }
}

/// Keyboard/VoiceOver step for the now-playing seek bar's adjustable action.
enum PlaybackSeekStep {
    /// Seconds moved per VoiceOver increment/decrement.
    static let seconds: TimeInterval = 10

    /// The clamped target position after stepping `forward` or backward from `position`.
    static func target(
        from position: TimeInterval, duration: TimeInterval, forward: Bool
    ) -> TimeInterval {
        let moved = position + (forward ? seconds : -seconds)
        return min(max(0, moved), max(0, duration))
    }
}

extension View {
    /// Adds an adjustable (swipe up/down) accessibility action only when `enabled`, so a
    /// read-only value is not announced as adjustable.
    @ViewBuilder
    func pillAdjustable(enabled: Bool, _ onAdjust: @escaping (AccessibilityAdjustmentDirection) -> Void) -> some View {
        if enabled {
            accessibilityAdjustableAction(onAdjust)
        } else {
            self
        }
    }
}

extension View {
    /// Rolling digits are macOS 14+. macOS 13 and motion-suppressed configurations use
    /// a quiet opacity replacement while keeping the same fixed-width monospaced layout.
    @ViewBuilder
    func availabilityGuardedNumericText(enabled: Bool = true) -> some View {
        if #available(macOS 14.0, *), enabled {
            contentTransition(.numericText())
        } else {
            contentTransition(.opacity)
        }
    }

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

    /// A control that behaves as a switch: VoiceOver reads the toggle trait on macOS 14+
    /// (`.isToggle`); on 13, where the trait does not exist, the hint says what the button does.
    @ViewBuilder
    func pillToggleSemantics(hint: String) -> some View {
        if #available(macOS 14.0, *) {
            accessibilityAddTraits(.isToggle)
        } else {
            accessibilityHint(Text(hint))
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

/// Re-renders time-derived text (an event countdown, a due label, a "10m" age) on a
/// wall-clock cadence. Nothing in a controller publishes when a clock merely moves, so
/// without this the labels freeze until an unrelated change. A `TimelineView` only ticks
/// while it is on screen, and the expanded layer is removed when the pill minimizes, so the
/// collapsed pill stays timer-free.
struct PillClock<Content: View>: View {
    enum Cadence { case minute, second }

    var cadence: Cadence = .minute
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        switch cadence {
        case .minute:
            TimelineView(.everyMinute) { context in content(context.date) }
        case .second:
            TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
        }
    }
}
