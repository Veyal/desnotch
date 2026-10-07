import SwiftUI

// MARK: - Layout and scrub math (pure)

/// Fixed geometry of the expanded now-playing row, shared by the view and its tests.
enum NowPlayingLayout {
    static let artSize: CGFloat = 40
    static let artRadius: CGFloat = 8
    /// Gap between artwork and text, and between the leading cluster and the transport.
    static let spacing: CGFloat = 10
    /// 24 (previous) + 32 (play/pause) + 24 (next) + two 4pt gaps.
    static let transportWidth: CGFloat = 88
    static let transportSpacing: CGFloat = 4
    static let titleLineHeight: CGFloat = 15
    static let artistLineHeight: CGFloat = 13
    static let timeLabelMinWidth: CGFloat = 30
    static let timeLabelSpacing: CGFloat = 8

    /// Width the title/artist column may use: whatever is left after the artwork, the
    /// transport and an 8pt breathing gap, never below 96pt.
    static func textColumnWidth(contentWidth: CGFloat) -> CGFloat {
        max(96, contentWidth - artSize - spacing - transportWidth - 8)
    }

    /// Estimated width of the progress bar between the two time labels (drives the redraw
    /// cadence; the bar itself lays out from real geometry).
    static func progressBarWidth(contentWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - 2 * (timeLabelMinWidth + timeLabelSpacing))
    }
}

/// Seek-bar pointer math.
enum PlaybackScrub {
    struct Sample: Equatable {
        /// Pointer position along the bar, clamped to 0...1.
        let fraction: CGFloat
        /// The pointer is at or past either end of the bar.
        let atEdge: Bool
    }

    static func sample(x: CGFloat, width: CGFloat) -> Sample? {
        guard width > 0, x.isFinite, width.isFinite else { return nil }
        return Sample(fraction: min(max(x / width, 0), 1), atEdge: x <= 0 || x >= width)
    }

    static func position(fraction: CGFloat, duration: TimeInterval) -> TimeInterval {
        TimeInterval(min(max(fraction, 0), 1)) * max(0, duration)
    }
}

// MARK: - Transport

/// Press feedback for a now-playing transport button: a quick spring squeeze with the
/// fill brightening, and a springy release that overshoots slightly (tactile). Under
/// Reduce Motion / Minimal there is no squeeze - only the fill and a slight dim carry the
/// press. Fills are opaque grays (identical to white-over-black), so Reduce Transparency
/// needs no special case.
struct NowPlayingTransportButtonStyle: ButtonStyle {
    let motion: NotchAnimation.Motion
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        PressFeedback(configuration: configuration, motion: motion, filled: filled)
    }

    private struct PressFeedback: View {
        let configuration: ButtonStyleConfiguration
        let motion: NotchAnimation.Motion
        let filled: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast

        private var fill: Color {
            if configuration.isPressed { return Color(white: 0.18) }
            return filled ? Color(white: 0.10) : .clear
        }

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed && !motion.allowsGeometry ? 0.7 : 1)
                .background(Circle().fill(fill))
                .scaleEffect(configuration.isPressed && motion.allowsGeometry ? motion.iconPressScale : 1)
                .animation(configuration.isPressed ? motion.press : motion.release, value: configuration.isPressed)
                .pillFocusRing(Circle(), isFocused: isFocused, increasedContrast: contrast == .increased)
        }
    }
}

/// Swaps a symbol: the system replace effect on macOS 14+ when pulses are allowed,
/// otherwise a short crossfade between two views (keyed on the symbol). The caller owns
/// the animation (`.animation(_, value:)`).
private struct SymbolSwap: ViewModifier {
    let key: String
    let useEffect: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *), useEffect {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content.id(key).transition(.opacity)
        }
    }
}

/// One transport button. Keeps the optimistic toggle design intact: the action calls the
/// controller exactly as before and the glyph follows `controller.info.isPlaying` (which
/// the controller flips optimistically), so the morph starts on the tap, not after the
/// MediaRemote round-trip.
@MainActor
struct NowPlayingTransportButton: View {
    let systemName: String
    let label: String
    let side: CGFloat
    let glyphSize: CGFloat
    let filled: Bool
    /// -1 / +1 slides the glyph that way on tap (previous / next); 0 = no slide.
    let nudgeDirection: CGFloat
    /// The glyph changes with playback state (play/pause) and should morph.
    var morphs = false
    let motion: NotchAnimation.Motion
    /// Runs the controller action; returns whether it took effect (a coalesced repeat tap
    /// is ignored by the controller and must not buzz).
    let action: () -> Bool

    @State private var nudge: CGFloat = 0
    @State private var nudgeToken = 0

    var body: some View {
        Button {
            if action() {
                PillHaptics.play(.transport)
            }
            playNudge()
        } label: {
            glyph
                .offset(x: nudge)
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(NowPlayingTransportButtonStyle(motion: motion, filled: filled))
        .help(label)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: systemName)
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(.white)
        if morphs {
            image
                .modifier(SymbolSwap(key: systemName, useEffect: motion.allowsPulse))
                .animation(motion.swap, value: systemName)
        } else {
            image
        }
    }

    private func playNudge() {
        let distance = nudgeDirection * motion.transportNudge
        guard distance != 0 else { return }
        nudgeToken += 1
        let token = nudgeToken
        withAnimation(motion.press) { nudge = distance }
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.pressHold) {
            guard token == nudgeToken else { return }
            withAnimation(motion.release) { nudge = 0 }
        }
    }
}

// MARK: - Progress

/// Elapsed/total readout with a progress bar. The `TimelineView` redraws at the resolved
/// progress cadence (`PillProgressCadence`, typically 1-2 fps) and only while the pill is
/// fully expanded, the track is playing and no scrub is in flight; the position is
/// extrapolated from the last adapter update, with no extra polling.
///
/// Draggable when enabled in Settings: drag or click the bar to seek. While scrubbing the
/// local `scrubPosition` follows the pointer on the direct-manipulation spring, then is
/// handed to `NowPlayingController.seek` on release (optimistic, so the bar does not snap
/// back). VoiceOver sees one adjustable element, unchanged.
@MainActor
struct NowPlayingProgressRow: View {
    let info: NowPlayingInfo
    let duration: TimeInterval
    let controller: NowPlayingController
    let motion: NotchAnimation.Motion
    let accent: Color
    let seekEnabled: Bool
    /// The pill is fully expanded (not mid-transition): the only time the timeline runs.
    let isActive: Bool
    let contentWidth: CGFloat
    @Binding var scrubPosition: TimeInterval?

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var edgeHapticFired = false

    private var scrubbing: Bool { scrubPosition != nil }

    var body: some View {
        let cadence = PillProgressCadence.interval(
            barWidth: NowPlayingLayout.progressBarWidth(contentWidth: contentWidth),
            duration: duration,
            minimum: motion.progressMinimumInterval
        )
        TimelineView(.animation(
            minimumInterval: cadence,
            paused: !info.isPlaying || scrubbing || !isActive
        )) { context in
            let live = min(max(info.position(at: context.date) ?? 0, 0), duration)
            let position = scrubPosition ?? live
            let fraction = duration > 0 ? CGFloat(position / duration) : 0
            HStack(spacing: NowPlayingLayout.timeLabelSpacing) {
                elapsedLabel(position)
                bar(fraction: fraction)
                Text(TimeFormatting.clock(duration))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(PillPalette.secondaryText(increasedContrast: contrast == .increased))
                    .frame(minWidth: NowPlayingLayout.timeLabelMinWidth, alignment: .trailing)
            }
            // One element for the whole bar: the visual readouts and capsule are
            // redundant with the label/value. When seeking is enabled it is adjustable
            // (VoiceOver swipe up/down), stepping through the same optimistic
            // `controller.seek` path the drag uses.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Playback position"))
            .accessibilityValue(Text("\(TimeFormatting.clock(position)) of \(TimeFormatting.clock(duration))"))
            .pillAdjustable(enabled: seekEnabled) { direction in
                switch direction {
                case .increment:
                    controller.seek(to: PlaybackSeekStep.target(from: position, duration: duration, forward: true))
                case .decrement:
                    controller.seek(to: PlaybackSeekStep.target(from: position, duration: duration, forward: false))
                @unknown default:
                    break
                }
            }
        }
        .onDisappear {
            // A drag interrupted by a collapse never delivers `onEnded`; don't leave the
            // bar frozen on a stale scrub position.
            scrubPosition = nil
        }
    }

    /// The elapsed time, which becomes the scrub target (white, heavier) while dragging.
    private func elapsedLabel(_ position: TimeInterval) -> some View {
        let secondary = PillPalette.secondaryText(increasedContrast: contrast == .increased)
        return Text(TimeFormatting.clock(position))
            .font(.system(size: scrubbing ? 11 : 10, weight: scrubbing ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(scrubbing ? Color.white : secondary)
            .availabilityGuardedNumericText(enabled: motion.allowsGeometry)
            .animation(scrubbing ? nil : motion.fade, value: Int(position))
            .frame(minWidth: NowPlayingLayout.timeLabelMinWidth, alignment: .leading)
    }

    private func bar(fraction: CGFloat) -> some View {
        // Geometric emphasis (the bar and knob growing while held) is dropped under
        // Minimal/Reduce Motion; the knob stays a constant size and still tracks the drag.
        let grows = motion.allowsGeometry
        let trackHeight: CGFloat = grows && scrubbing ? 8 : 4
        let knob: CGFloat = grows ? (scrubbing ? 12 : 5) : 8
        let trackFill = PillPalette.seekTrack(increasedContrast: contrast == .increased)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(accent)
                    .frame(width: max(0, geo.size.width * fraction), height: trackHeight)
                if seekEnabled {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .offset(x: geo.size.width * fraction - knob / 2)
                }
            }
            .animation(scrubbing ? motion.direct : nil, value: fraction)
            .animation(scrubbing ? motion.press : motion.release, value: scrubbing)
            // 24pt hit area inside the 20pt row, re-centered on it.
            .frame(width: geo.size.width, height: 24)
            .offset(y: -2)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: geo.size.width))
        }
        .frame(height: 20)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        // minimumDistance 0 makes a plain click seek too, not just a drag.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard seekEnabled, let sample = PlaybackScrub.sample(x: value.location.x, width: width) else {
                    return
                }
                if scrubPosition == nil {
                    edgeHapticFired = false
                    PillHaptics.play(.scrubBegin)
                }
                scrubPosition = PlaybackScrub.position(fraction: sample.fraction, duration: duration)
                if sample.atEdge, !edgeHapticFired {
                    edgeHapticFired = true
                    PillHaptics.play(.scrubEdge)
                }
            }
            .onEnded { _ in
                guard seekEnabled, let target = scrubPosition else { return }
                controller.seek(to: target)
                scrubPosition = nil
                PillHaptics.play(.scrubCommit)
            }
    }
}
