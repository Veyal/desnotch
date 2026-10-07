import SwiftUI

/// The expanded now-playing section: artwork (with an accent glow derived from it),
/// title/artist that swap on a track change (long titles scroll), the transport, and the
/// progress bar.
///
/// This is its own view rather than a `NotchPillView` extension so it can read the
/// accessibility environment (Reduce Transparency, Increase Contrast) directly. All
/// motion resolves through `motion`; the glow, the blur, the artwork pop and the marquee
/// all drop out under Reduce Motion/Minimal, and the glow and blur also drop out under
/// Reduce Transparency. Privacy mode blanks title/artist upstream and additionally turns
/// off the accent and glow here (the artwork's colors identify the track).
struct NowPlayingSectionView: View {
    let info: NowPlayingInfo
    /// Already passed through `privacyRedacted`.
    let title: String
    let artist: String
    let accessibilityText: String
    let controller: NowPlayingController
    let motion: NotchAnimation.Motion
    let phase: PillExpansionPhase
    let contentWidth: CGFloat
    let privacy: Bool
    let seekEnabled: Bool
    /// The user picked the equalizer music indicator: it also animates over the artwork
    /// while the pill is fully expanded and playing (no new perpetual motion for anyone
    /// who has not opted in).
    let equalizerOverArtwork: Bool
    @Binding var scrubPosition: TimeInterval?
    let onActivate: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var isExpanded: Bool { phase == .expanded }

    private var blurAllowed: Bool { motion.allowsBlur && !reduceTransparency }

    /// Identity of the visible text, so the swap transition replays only on a real change
    /// (and never in privacy mode, where the text is constant).
    private var textKey: String { privacy ? "private" : info.trackTextKey }

    private var artworkKey: ObjectIdentifier? { info.artwork.map(ObjectIdentifier.init) }

    private var accentColor: NSColor? {
        guard !privacy, let accent = info.accent else { return nil }
        return contrast == .increased
            ? PillPalette.lift(accent, toMinLuminance: PillPalette.increasedContrastLuminanceOnBlack)
            : accent
    }

    private var accent: Color { accentColor.map { Color(nsColor: $0) } ?? .white }

    private var glowAccent: NSColor? {
        motion.allowsAmbient && !reduceTransparency ? accentColor : nil
    }

    private var showsEqualizer: Bool {
        equalizerOverArtwork && motion.allowsLooping && info.isPlaying && isExpanded
    }

    var body: some View {
        VStack(spacing: 8) {
            controlsRow
            if let duration = info.duration, duration > 0, info.elapsed != nil {
                NowPlayingProgressRow(
                    info: info,
                    duration: duration,
                    controller: controller,
                    motion: motion,
                    accent: accent,
                    seekEnabled: seekEnabled,
                    isActive: isExpanded,
                    contentWidth: contentWidth,
                    scrubPosition: $scrubPosition
                )
            }
        }
        .background {
            if glowAccent != nil {
                ArtworkGlow(accent: glowAccent, isPlaying: info.isPlaying, motion: motion)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -4)
            }
        }
    }

    // MARK: Row

    private var controlsRow: some View {
        HStack(spacing: 0) {
            // Artwork + titles jump to the app that's playing; the transport buttons keep
            // their own actions, so only the leading cluster is tappable.
            Button(action: onActivate) {
                HStack(spacing: NowPlayingLayout.spacing) {
                    artworkView
                    titles
                        .frame(
                            maxWidth: NowPlayingLayout.textColumnWidth(contentWidth: contentWidth),
                            alignment: .leading
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(NowPlayingOpenButtonStyle(motion: motion))
            .help(motion.allowsGeometry ? "Open the playing app" : "\(title) - Open the playing app")
            .accessibilityLabel(Text(accessibilityText))
            .accessibilityHint(Text("Opens the playing app"))

            Spacer(minLength: 4)

            transport
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Artwork

    private var artworkView: some View {
        let shape = RoundedRectangle(cornerRadius: NowPlayingLayout.artRadius, style: .continuous)
        return ZStack {
            artworkContent
                .id(artworkKey)
                .transition(.asymmetric(
                    insertion: motion.artArrivalScale == 1
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: motion.artArrivalScale)),
                    removal: .opacity
                ))
        }
        .frame(width: NowPlayingLayout.artSize, height: NowPlayingLayout.artSize)
        .animation(motion.swap, value: artworkKey)
        .clipShape(shape)
        .overlay(shape.strokeBorder(
            PillPalette.artworkEdge(increasedContrast: contrast == .increased), lineWidth: 0.5
        ))
        .overlay { equalizerOverlay }
        .animation(motion.fade, value: showsEqualizer)
        // Play/pause: the art pops back to full size on play and settles slightly smaller
        // and dimmer on pause. The scale is geometric (dropped for Reduce Motion); the dim
        // carries the state on its own.
        .scaleEffect(info.isPlaying ? 1 : motion.artPauseScale)
        .animation(motion.release, value: info.isPlaying)
        .opacity(info.isPlaying ? 1 : motion.artPausedOpacity)
        .animation(motion.swap, value: info.isPlaying)
    }

    @ViewBuilder
    private var artworkContent: some View {
        if let image = info.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: NowPlayingLayout.artSize, height: NowPlayingLayout.artSize)
                .clipped()
        } else {
            ZStack {
                PillPalette.surfaceControl
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PillPalette.slateGray)
            }
        }
    }

    @ViewBuilder
    private var equalizerOverlay: some View {
        if showsEqualizer {
            ZStack {
                Color.black.opacity(0.40)
                NowPlayingEqualizer(
                    bars: NowPlayingEqualizer.expandedBarCount,
                    barWidth: 3, spacing: 2, minHeight: 4, maxHeight: 14,
                    tint: accent,
                    paused: !isExpanded
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: NowPlayingLayout.artRadius, style: .continuous))
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    // MARK: Titles

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .leading) {
                PillMarqueeText(
                    text: title,
                    font: .system(size: 12, weight: .semibold),
                    color: .white,
                    lineHeight: NowPlayingLayout.titleLineHeight,
                    isActive: isExpanded,
                    allowsScroll: motion.allowsGeometry,
                    fadeAnimation: motion.fade
                )
                .id(textKey)
                .transition(.pillBlurSlide(motion, blurAllowed: blurAllowed))
            }
            .frame(height: NowPlayingLayout.titleLineHeight)
            .clipped()

            // No artist (Privacy mode blanks it, or the track has none): drop the reserved
            // line so the lone title centres against the artwork and transport instead of
            // sitting on the first of two lines.
            if !artist.isEmpty {
                ZStack(alignment: .leading) {
                    Text(artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PillPalette.secondaryText(increasedContrast: contrast == .increased))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(textKey)
                        .transition(.pillBlurSlide(motion, blurAllowed: blurAllowed, secondLine: true))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: NowPlayingLayout.artistLineHeight)
                .clipped()
            }
        }
        .animation(motion.swap, value: textKey)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: NowPlayingLayout.transportSpacing) {
            NowPlayingTransportButton(
                systemName: "backward.fill", label: "Previous track",
                side: 24, glyphSize: 12, filled: false, nudgeDirection: -1, motion: motion
            ) {
                controller.previous()
                return true
            }
            NowPlayingTransportButton(
                systemName: info.isPlaying ? "pause.fill" : "play.fill",
                label: info.isPlaying ? "Pause" : "Play",
                side: 32, glyphSize: 14, filled: true, nudgeDirection: 0, morphs: true, motion: motion
            ) {
                // The controller flips `info.isPlaying` optimistically and synchronously
                // (and ignores a coalesced repeat tap); the glyph and artwork follow that
                // value, so the morph starts on the tap. Only buzz when it took effect.
                let before = controller.info?.isPlaying
                controller.togglePlayPause()
                return controller.info?.isPlaying != before
            }
            NowPlayingTransportButton(
                systemName: "forward.fill", label: "Next track",
                side: 24, glyphSize: 12, filled: false, nudgeDirection: 1, motion: motion
            ) {
                controller.next()
                return true
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Row highlight for the leading artwork/title cluster. Unlike an icon, a wide row must
/// not squeeze when pressed (a 270pt row shrinking 10% reads as broken): the press is a
/// soft rounded highlight only.
struct NowPlayingOpenButtonStyle: ButtonStyle {
    let motion: NotchAnimation.Motion

    func makeBody(configuration: Configuration) -> some View {
        PressFeedback(configuration: configuration, motion: motion)
    }

    private struct PressFeedback: View {
        let configuration: ButtonStyleConfiguration
        let motion: NotchAnimation.Motion
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        var body: some View {
            let highlight = RoundedRectangle(cornerRadius: 10, style: .continuous)
            configuration.label
                .background(
                    highlight
                        .fill(PillSurface.highlight(
                            base: reduceTransparency ? 0.10 : 0.08,
                            reduceTransparency: reduceTransparency,
                            increasedContrast: contrast == .increased
                        ))
                        .padding(.horizontal, -4)
                        .padding(.vertical, -2)
                        .opacity(configuration.isPressed ? 1 : 0)
                )
                .animation(configuration.isPressed ? motion.press : motion.release, value: configuration.isPressed)
                .pillFocusRing(
                    highlight, isFocused: isFocused, increasedContrast: contrast == .increased,
                    horizontalBleed: -4, verticalBleed: -2
                )
        }
    }
}

/// A soft single-hue glow behind the now-playing row, tinted by the artwork accent. Cheap
/// by construction: one static radial gradient (no blur, no shadow) whose opacity is the
/// only thing that animates. A track change crossfades between two layers (ping-pong) so
/// the old tint fades out while the new one fades in, instead of snapping.
struct ArtworkGlow: View {
    let accent: NSColor?
    let isPlaying: Bool
    let motion: NotchAnimation.Motion

    /// Gradient peak while playing; paused dims it to 0.10 (`pausedFactor` of the peak).
    private static let playingOpacity = 0.28
    private static let pausedFactor = 0.10 / 0.28

    @State private var colorA: NSColor?
    @State private var colorB: NSColor?
    @State private var showsA = true

    init(accent: NSColor?, isPlaying: Bool, motion: NotchAnimation.Motion) {
        self.accent = accent
        self.isPlaying = isPlaying
        self.motion = motion
        _colorA = State(initialValue: accent)
    }

    private var key: String { ArtworkAccent.key(for: accent) }

    /// What `onChange` watches: equal while the quantized key is, but it carries the new colour
    /// so the closure never reads `accent` through `self` (that returns the previous render's
    /// value there, which left the glow one track behind).
    private struct AccentChange: Equatable {
        let key: String
        let color: NSColor?
        static func == (lhs: AccentChange, rhs: AccentChange) -> Bool { lhs.key == rhs.key }
    }

    var body: some View {
        ZStack {
            layer(colorA).opacity(showsA ? 1 : 0)
            layer(colorB).opacity(showsA ? 0 : 1)
        }
        .opacity(isPlaying ? 1 : Self.pausedFactor)
        .animation(motion.swap, value: isPlaying)
        .onChange(of: AccentChange(key: key, color: accent)) { new in crossfade(to: new.color) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layer(_ color: NSColor?) -> some View {
        if let color {
            RadialGradient(
                colors: [Color(nsColor: color).opacity(Self.playingOpacity), .clear],
                center: .leading,
                startRadius: 0,
                endRadius: 150
            )
        }
    }

    private func crossfade(to color: NSColor?) {
        if showsA {
            colorB = color
        } else {
            colorA = color
        }
        withAnimation(motion.accentCrossfade) { showsA.toggle() }
    }
}
