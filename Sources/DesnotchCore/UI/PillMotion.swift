import SwiftUI

/// The pill's single motion vocabulary. Every animation in the pill resolves through
/// here so the feel stays consistent and one switch (`AnimationStyle`, or the system's
/// Reduce Motion) governs all of it.
///
/// Design intent, "fluid hardware extension": the black shape springs open like a living
/// extension of the notch, content is staged in afterwards (blur/scale/offset, staggered
/// per section), and exits are fast fades. Nothing loops continuously unless the user
/// opted into it, and Reduce Motion collapses the whole vocabulary to short fades.
///
/// Semantics (`AnimationStyle` raw values are persisted and never renamed):
/// - `.subtle` (default) = Fluid: ~2% shape overshoot, light blur.
/// - `.dynamic` = Lively: the same choreography with more overshoot, larger blur/offset and
///   a longer stagger.
/// - `.minimal` and Reduce Motion = identical token set: no geometry animation, no blur,
///   no scale, no loop, 120ms fades only.
///
/// Springs use `Animation.spring(response:dampingFraction:)` only (macOS 13 safe).
enum NotchAnimation {
    struct Motion: Equatable {
        // MARK: Structural (the shape and the layout it owns)

        /// Shape + container frame growth on expand. nil snaps (Minimal / Reduce Motion).
        let shapeOpen: Animation?
        /// Collapse back into the hardware. Critically damped so the pill never
        /// undershoots below the cutout.
        let shapeClose: Animation?
        /// Section insert/remove while the pill is open (`PillStructuralAnimationState`).
        let structural: Animation?

        // MARK: Content

        /// Per-section reveal after the shape has started growing.
        let contentIn: Animation
        /// Fast fade for exits (collapse, wing leave). Exits never spring.
        let contentOut: Animation
        /// Track/title/chip replacement and small state crossfades.
        let swap: Animation
        /// Micro state crossfades (rim glow in, dots).
        let fade: Animation
        /// Rim glow fading out after its hold.
        let glowOut: Animation
        /// Compact wing indicator appearing/swapping.
        let wing: Animation
        /// Control held down (a ~150ms micro-interaction).
        let press: Animation
        /// Control released: a little overshoot reads as tactile.
        let release: Animation
        /// Follows the pointer during direct manipulation (scrub). nil snaps.
        let direct: Animation?

        // MARK: Choreography timing (seconds)

        /// Content starts revealing this long after the shape starts growing.
        let shapeLeadDelay: TimeInterval
        /// The shape starts collapsing this long after the content starts fading.
        let collapseShapeDelay: TimeInterval
        /// Extra delay per section rank during the reveal stagger.
        let staggerStep: TimeInterval
        /// Rank beyond which sections share the last stagger delay.
        let staggerCap: Int
        /// How long a one-shot rim acknowledgement stays at full strength.
        let feedbackHold: TimeInterval

        // MARK: Reveal effect geometry

        /// Starting scale (anchor `.top`) of a section being revealed.
        let revealScale: CGFloat
        /// Starting vertical offset (negative = drops out of the notch).
        let revealOffsetY: CGFloat
        /// Starting blur radius of a section being revealed.
        let revealBlur: CGFloat
        /// Scale the compact wings shrink to while the pill opens.
        let compactLeaveScale: CGFloat
        /// Blur the compact wings pick up while the pill opens.
        let compactLeaveBlur: CGFloat
        /// A row inserted while the pill is open: starting scale / offset / blur.
        let rowArrivalScale: CGFloat
        let rowArrivalOffsetY: CGFloat
        let rowArrivalBlur: CGFloat
        /// Blur a removed row picks up while it fades.
        let rowRemovalBlur: CGFloat

        // MARK: Now playing

        /// Scale a pressed icon button squeezes to.
        let iconPressScale: CGFloat
        /// Artwork scale while paused (it pops back to 1 on play via `release`).
        let artPauseScale: CGFloat
        /// Artwork opacity while paused. Carries the play/pause state alone when the scale
        /// is suppressed.
        let artPausedOpacity: Double
        /// How far a previous/next glyph slides in its direction on tap.
        let transportNudge: CGFloat
        /// Vertical travel and blur of title/artist text swapping on a track change.
        let trackSwapOffset: CGFloat
        let trackSwapBlur: CGFloat
        /// Scale the incoming artwork starts at on a track change.
        let artArrivalScale: CGFloat

        // MARK: Section micro-interactions and wings

        /// Scale a pressed full-width row squeezes to (1 = highlight only).
        let rowPressScale: CGFloat
        /// A status chip changing state starts at this scale (and crossfades colour).
        let chipArrivalScale: CGFloat
        /// Peak scale of a one-shot pop (join capsule crossing into imminent, checkbox,
        /// battery bolt).
        let popScale: CGFloat
        /// The empty-tray drop well grows to this while a file hovers it.
        let dropWellScale: CGFloat
        /// Wing indicator swap: incoming starts / outgoing ends at these scales, with this
        /// much blur while swapping.
        let wingSwapScaleIn: CGFloat
        let wingSwapScaleOut: CGFloat
        let wingSwapBlur: CGFloat
        /// Finite attention ripple: passes, seconds per pass, seconds between passes, and
        /// the scale a ripple ring grows to (from 0.8). 0 passes = static tint only.
        let attentionPulseCount: Int
        let attentionPulseDuration: TimeInterval
        let attentionPulseGap: TimeInterval
        let ringPulseScale: CGFloat
        /// Peak opacity of the "this row just landed" highlight (0 = none) and how it fades.
        let landingFlashPeak: Double
        let landingFlashOut: Animation
        /// Seconds the completing reminder keeps its row (checkbox fill + strike draw)
        /// before leaving.
        let completionHold: TimeInterval
        /// Strike-through and timer check-mark draw durations (0 = instant).
        let strikeDuration: TimeInterval
        let checkDrawDuration: TimeInterval
        /// How long a one-shot press (pop, transport nudge) holds before it releases.
        let pressHold: TimeInterval
        /// How long a freshly landed row stays flagged before its highlight fades.
        let landingHold: TimeInterval
        /// Artwork-accent glow ping-pong crossfade on a track change.
        let accentCrossfade: Animation
        /// One-time light sweep across the battery fill on plug-in (0 = none).
        let sweepDuration: TimeInterval
        /// Delay before an incoming track-change line starts, and the extra lag of the
        /// second line behind the first.
        let trackSwapDelay: TimeInterval
        let trackSwapLineLag: TimeInterval

        // MARK: Flash-open spotlight

        /// Spotlight highlight stays fully lit this long, then fades.
        let spotlightHold: TimeInterval
        /// Highlight fade-out, and the other sections easing back from the dim.
        let spotlightHighlightOut: Animation
        let spotlightDimOut: Animation
        /// Opacity the non-spotlight sections start at during a flash (1 = no dimming).
        let spotlightDimOpacity: Double

        // MARK: Existing vocabulary (feel and perpetual-motion gates)

        /// Whether perpetual motion (the equalizer) may run at all.
        let allowsLooping: Bool
        /// Whether one-shot symbol pulses (needs-you bounce) may fire.
        let allowsPulse: Bool
        /// Geometric squeeze for a pressed control. Reduce Motion resolves this to 1.
        let pressScale: CGFloat
        /// Cadence for client-side progress readouts. This is not a polling interval.
        let progressMinimumInterval: TimeInterval
        /// Cadence for the opt-in equalizer loop.
        let equalizerMinimumInterval: TimeInterval
        /// How long Approve must be held on an agent card. A safety gesture, so every
        /// token set uses the same duration: Minimal and Reduce Motion must not shorten it.
        let approveHoldDuration: TimeInterval

        /// Whether size/position-based emphasis (press scale, scrub-knob growth, reveal
        /// offset/scale, row slides) may be used at all. Reduce Motion's central complaint
        /// is geometric movement, so under Minimal/Reduce Motion feedback must be carried
        /// by opacity instead - never by moving or resizing things.
        var allowsGeometry: Bool {
            revealOffsetY != 0 || revealScale != 1 || rowArrivalOffsetY != 0
                || rowArrivalScale != 1 || pressScale != 1
        }

        /// Whether one-shot attention ripples may run.
        var allowsRipple: Bool { attentionPulseCount > 0 }

        /// Whether blur-based reveals may be used (also gated by Reduce Transparency at
        /// the call site, where the environment is available).
        var allowsBlur: Bool { revealBlur > 0 }

        /// Whether purely decorative ambience (the artwork glow) may render. It follows
        /// geometry rather than blur: Reduce Motion and Minimal drop it entirely.
        var allowsAmbient: Bool { allowsGeometry }
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
        guard !reduceMotion, style != .minimal else { return .minimal }
        return style == .dynamic ? .lively : .fluid
    }
}

extension NotchAnimation.Motion {
    /// Minimal / Reduce Motion: geometry snaps, content is a 120ms fade, nothing loops.
    static let minimal = NotchAnimation.Motion(
        shapeOpen: nil,
        shapeClose: nil,
        structural: nil,
        contentIn: .easeOut(duration: 0.12),
        contentOut: .easeInOut(duration: 0.12),
        swap: .easeInOut(duration: 0.12),
        fade: .easeInOut(duration: 0.12),
        glowOut: .easeOut(duration: 0.12),
        wing: .easeInOut(duration: 0.12),
        press: .easeOut(duration: 0.12),
        release: .easeOut(duration: 0.12),
        direct: nil,
        shapeLeadDelay: 0,
        collapseShapeDelay: 0,
        staggerStep: 0,
        staggerCap: 0,
        feedbackHold: 0.08,
        revealScale: 1,
        revealOffsetY: 0,
        revealBlur: 0,
        compactLeaveScale: 1,
        compactLeaveBlur: 0,
        rowArrivalScale: 1,
        rowArrivalOffsetY: 0,
        rowArrivalBlur: 0,
        rowRemovalBlur: 0,
        iconPressScale: 1,
        artPauseScale: 1,
        artPausedOpacity: 0.6,
        transportNudge: 0,
        trackSwapOffset: 0,
        trackSwapBlur: 0,
        artArrivalScale: 1,
        rowPressScale: 1,
        chipArrivalScale: 1,
        popScale: 1,
        dropWellScale: 1,
        wingSwapScaleIn: 1,
        wingSwapScaleOut: 1,
        wingSwapBlur: 0,
        attentionPulseCount: 0,
        attentionPulseDuration: 0,
        attentionPulseGap: 0,
        ringPulseScale: 1,
        landingFlashPeak: 0,
        landingFlashOut: .easeOut(duration: 0.12),
        completionHold: 0.25,
        strikeDuration: 0,
        checkDrawDuration: 0,
        pressHold: 0.08,
        landingHold: 0.12,
        accentCrossfade: .easeInOut(duration: 0.12),
        sweepDuration: 0,
        trackSwapDelay: 0,
        trackSwapLineLag: 0,
        spotlightHold: 0.12,
        spotlightHighlightOut: .easeOut(duration: 0.6),
        spotlightDimOut: .easeOut(duration: 0.12),
        spotlightDimOpacity: 1,
        allowsLooping: false,
        allowsPulse: false,
        pressScale: 1,
        progressMinimumInterval: 1,
        equalizerMinimumInterval: 1,
        approveHoldDuration: 0.6
    )

    /// `.subtle`: the shipped "fluid hardware extension" feel. About 2% overshoot on
    /// open (settles in ~0.38s), critically damped close (~0.23s), 35ms section stagger.
    static let fluid = NotchAnimation.Motion(
        shapeOpen: .spring(response: 0.46, dampingFraction: 0.78),
        shapeClose: .spring(response: 0.36, dampingFraction: 1.0),
        structural: .spring(response: 0.42, dampingFraction: 0.86),
        contentIn: .spring(response: 0.38, dampingFraction: 0.84),
        contentOut: .easeIn(duration: 0.12),
        swap: .easeInOut(duration: 0.20),
        fade: .easeInOut(duration: 0.12),
        glowOut: .easeOut(duration: 0.30),
        wing: .spring(response: 0.30, dampingFraction: 0.82),
        press: .spring(response: 0.18, dampingFraction: 0.90),
        release: .spring(response: 0.30, dampingFraction: 0.50),
        direct: .interactiveSpring(response: 0.15, dampingFraction: 0.86),
        shapeLeadDelay: 0.060,
        collapseShapeDelay: 0.050,
        staggerStep: 0.035,
        staggerCap: 6,
        feedbackHold: 0.14,
        revealScale: 0.95,
        revealOffsetY: -8,
        revealBlur: 4,
        compactLeaveScale: 0.85,
        compactLeaveBlur: 3,
        rowArrivalScale: 0.96,
        rowArrivalOffsetY: -6,
        rowArrivalBlur: 3,
        rowRemovalBlur: 3,
        iconPressScale: 0.90,
        artPauseScale: 0.92,
        artPausedOpacity: 0.75,
        transportNudge: 3,
        trackSwapOffset: 4,
        trackSwapBlur: 3,
        artArrivalScale: 0.94,
        rowPressScale: 1,
        chipArrivalScale: 0.94,
        popScale: 1.06,
        dropWellScale: 1.015,
        wingSwapScaleIn: 0.70,
        wingSwapScaleOut: 0.85,
        wingSwapBlur: 2,
        attentionPulseCount: 2,
        attentionPulseDuration: 0.70,
        attentionPulseGap: 0.15,
        ringPulseScale: 1.6,
        landingFlashPeak: 0.12,
        landingFlashOut: .easeOut(duration: 0.60),
        completionHold: 0.40,
        strikeDuration: 0.20,
        checkDrawDuration: 0.35,
        pressHold: 0.10,
        landingHold: 0.12,
        accentCrossfade: .easeInOut(duration: 0.40),
        sweepDuration: 0.60,
        trackSwapDelay: 0.06,
        trackSwapLineLag: 0.03,
        spotlightHold: 0.30,
        spotlightHighlightOut: .easeOut(duration: 0.90),
        spotlightDimOut: .easeOut(duration: 0.70),
        spotlightDimOpacity: 0.55,
        allowsLooping: true,
        allowsPulse: true,
        pressScale: 0.96,
        progressMinimumInterval: 1.0 / 15.0,
        equalizerMinimumInterval: 1.0 / 15.0,
        approveHoldDuration: 0.6
    )

    /// `.dynamic`: the same choreography, livelier (more overshoot, bigger blur/offset,
    /// 1.25x stagger).
    static let lively = NotchAnimation.Motion(
        shapeOpen: .spring(response: 0.52, dampingFraction: 0.68),
        shapeClose: .spring(response: 0.40, dampingFraction: 0.92),
        structural: .spring(response: 0.48, dampingFraction: 0.74),
        contentIn: .spring(response: 0.42, dampingFraction: 0.74),
        contentOut: .easeIn(duration: 0.14),
        swap: .spring(response: 0.34, dampingFraction: 0.80),
        fade: .easeInOut(duration: 0.12),
        glowOut: .easeOut(duration: 0.30),
        wing: .spring(response: 0.32, dampingFraction: 0.68),
        press: .spring(response: 0.16, dampingFraction: 0.80),
        release: .spring(response: 0.28, dampingFraction: 0.45),
        direct: .interactiveSpring(response: 0.15, dampingFraction: 0.86),
        shapeLeadDelay: 0.070,
        collapseShapeDelay: 0.060,
        staggerStep: 0.045,
        staggerCap: 6,
        feedbackHold: 0.16,
        revealScale: 0.92,
        revealOffsetY: -10,
        revealBlur: 6,
        compactLeaveScale: 0.80,
        compactLeaveBlur: 4,
        rowArrivalScale: 0.92,
        rowArrivalOffsetY: -8,
        rowArrivalBlur: 4,
        rowRemovalBlur: 4,
        iconPressScale: 0.86,
        artPauseScale: 0.88,
        artPausedOpacity: 0.75,
        transportNudge: 4,
        trackSwapOffset: 6,
        trackSwapBlur: 4,
        artArrivalScale: 0.90,
        rowPressScale: 0.985,
        chipArrivalScale: 0.90,
        popScale: 1.10,
        dropWellScale: 1.025,
        wingSwapScaleIn: 0.55,
        wingSwapScaleOut: 0.80,
        wingSwapBlur: 3,
        attentionPulseCount: 3,
        attentionPulseDuration: 0.80,
        attentionPulseGap: 0.12,
        ringPulseScale: 1.8,
        landingFlashPeak: 0.14,
        landingFlashOut: .easeOut(duration: 0.60),
        completionHold: 0.40,
        strikeDuration: 0.20,
        checkDrawDuration: 0.35,
        pressHold: 0.10,
        landingHold: 0.12,
        accentCrossfade: .easeInOut(duration: 0.40),
        sweepDuration: 0.60,
        trackSwapDelay: 0.06,
        trackSwapLineLag: 0.03,
        spotlightHold: 0.30,
        spotlightHighlightOut: .easeOut(duration: 0.90),
        spotlightDimOut: .easeOut(duration: 0.70),
        spotlightDimOpacity: 0.55,
        allowsLooping: true,
        allowsPulse: true,
        pressScale: 0.90,
        progressMinimumInterval: 1.0 / 15.0,
        equalizerMinimumInterval: 1.0 / 15.0,
        approveHoldDuration: 0.6
    )
}

// MARK: - Sections and stagger

/// The expanded pill's sections in their stacking order (top to bottom). The order is also
/// the reveal-stagger rank, so adding a section means adding a case in its visual position.
enum PillSectionKind: CaseIterable, Hashable {
    case voice, notification, media, timer, agents, processes, calendar, reminders, battery,
         clipboard, privacy, tray

    /// Position in the stack (top = 0): the reveal-stagger rank and the staged-mount cursor.
    var order: Int {
        switch self {
        case .voice: return 0
        case .notification: return 1
        case .media: return 2
        case .timer: return 3
        case .agents: return 4
        case .processes: return 5
        case .calendar: return 6
        case .reminders: return 7
        case .battery: return 8
        case .clipboard: return 9
        case .privacy: return 10
        case .tray: return 11
        }
    }
}

/// Pure stagger math for the section reveal.
enum PillStagger {
    /// Delay for the nth item. `index` is clamped to `0...cap`.
    static func delay(index: Int, step: TimeInterval, cap: Int) -> TimeInterval {
        step * Double(min(max(index, 0), max(cap, 0)))
    }

    /// Reveal rank of `kind`. With a `spotlight` the spotlighted section ranks 0 and every
    /// section that was above it shifts down by one; the rest keep their natural rank.
    static func rank(
        of kind: PillSectionKind,
        order: [PillSectionKind] = PillSectionKind.allCases,
        spotlight: PillSectionKind?
    ) -> Int {
        guard let index = order.firstIndex(of: kind) else { return 0 }
        guard let spotlight, let spotlightIndex = order.firstIndex(of: spotlight) else {
            return index
        }
        if kind == spotlight { return 0 }
        return index < spotlightIndex ? index + 1 : index
    }
}

// MARK: - Reveal and arrival modifiers

/// How a section relates to a running flash-open spotlight.
enum PillSpotlightRole: Equatable {
    /// No flash is running.
    case none
    /// The section the flash is about: gets the highlight.
    case lead
    /// Every other section: starts dimmed and eases back to full opacity.
    case follower
}

/// Geometry of the flash-open spotlight card behind a section. The content sits 16pt inside
/// the pill frame, and the silhouette's concave top ears already take 6pt of each side, so a
/// card that bleeds much past the content lands a few points from the visible edge.
enum SpotlightCard {
    static let cornerRadius: CGFloat = 12
    static let horizontalBleed: CGFloat = 4
    static let verticalBleed: CGFloat = 4
    /// What the last section's card may reach below its content.
    static let lastSectionBottomBleed: CGFloat = 2

    /// The pill's bottom corners (`expandedBottomRadius`) curve in `r - sqrt(r^2 - (r - d)^2)`
    /// points at height `d` above the bottom: 3.2pt at the 12pt content inset, 4.5pt at 10pt,
    /// 6.1pt at 8pt. A card reaching as low as the usual 4pt bleed would be clipped by the
    /// corner, so the last section's card reaches only `lastSectionBottomBleed`.
    static func bottomBleed(isLastInStack: Bool) -> CGFloat {
        isLastInStack ? lastSectionBottomBleed : verticalBleed
    }

    /// How far the silhouette's rounded bottom corner is inset from the pill's side `above`
    /// points above the bottom edge.
    static func cornerInset(above: CGFloat, radius: CGFloat = NotchGeometry.expandedBottomRadius) -> CGFloat {
        guard above < radius else { return 0 }
        return radius - (radius * radius - (radius - above) * (radius - above)).squareRoot()
    }
}

/// Reveals one section of the expanded pill: opacity + scale + offset + blur, delayed by
/// the section's stagger rank on the way in and instant (all sections together) on the
/// way out. The `.animation(_:value:)` calls are scoped to this leaf wrapper and keyed to
/// values only the expansion choreography and the flash spotlight mutate, so they do not
/// violate the "no broad animation on the root" rule.
struct PillRevealModifier: ViewModifier {
    let visible: Bool
    let rank: Int
    let motion: NotchAnimation.Motion
    let blurAllowed: Bool
    let role: PillSpotlightRole
    let spotlightLit: Bool
    /// The last section of the stack: its highlight card ends at the content edge instead of
    /// bleeding below it, because the pill's expanded bottom corners curve in over exactly that
    /// band and would clip the card's own corners (see `SpotlightCard`).
    var isLastInStack = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Spotlight highlight fill: `white 0.07` over black, an opaque equivalent under Reduce
    /// Transparency, a touch stronger under Increase Contrast.
    private var highlightFill: Color {
        PillSurface.highlight(base: 0.07, reduceTransparency: reduceTransparency,
                              increasedContrast: contrast == .increased)
    }

    private var dimFactor: Double {
        role == .follower && spotlightLit ? motion.spotlightDimOpacity : 1
    }

    private var highlightOpacity: Double {
        role == .lead && spotlightLit ? 1 : 0
    }

    private var revealAnimation: Animation {
        visible
            ? motion.contentIn.delay(
                PillStagger.delay(index: rank, step: motion.staggerStep, cap: motion.staggerCap)
            )
            : motion.contentOut
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: SpotlightCard.cornerRadius, style: .continuous)
                    .fill(highlightFill)
                    .padding(.horizontal, -SpotlightCard.horizontalBleed)
                    .padding(.top, -SpotlightCard.verticalBleed)
                    .padding(.bottom, -SpotlightCard.bottomBleed(isLastInStack: isLastInStack))
                    .opacity(highlightOpacity)
                    .animation(
                        spotlightLit ? motion.fade : motion.spotlightHighlightOut,
                        value: spotlightLit
                    )
                    .allowsHitTesting(false)
            )
            .opacity(dimFactor)
            .animation(spotlightLit ? motion.fade : motion.spotlightDimOut, value: spotlightLit)
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : motion.revealScale, anchor: .top)
            .offset(y: visible ? 0 : motion.revealOffsetY)
            .blur(radius: visible || !blurAllowed ? 0 : motion.revealBlur)
            .animation(revealAnimation, value: visible)
    }
}

/// Transition payload for rows and wings entering/leaving: fade plus optional
/// scale/offset/blur. Travel stays bounded (a few points) rather than `.move(edge:)`,
/// which dragged a row its full height.
struct PillArrivalModifier: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let verticalOffset: CGFloat
    var blur: CGFloat = 0
    var anchor: UnitPoint = .top

    /// A view mid-transition is invisible at the active end (opacity 0), so it must not be
    /// reachable either: without this a leaving row/track line stays an accessibility
    /// element until its fade finishes, and VoiceOver reads the old and new content twice.
    /// The flag flips with the transition, not with the interpolated opacity, so the
    /// outgoing element leaves the tree at once and the incoming one joins it as it starts.
    static func hidesFromAccessibility(opacity: Double) -> Bool { opacity < 1 }

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale, anchor: anchor)
            .offset(y: verticalOffset)
            .blur(radius: blur)
            .accessibilityHidden(Self.hidesFromAccessibility(opacity: opacity))
    }
}

extension AnyTransition {
    /// A plain fade for controls that swap in place (timer buttons, a reminder row), which
    /// also drops the leaving control from the accessibility tree immediately.
    static var pillFade: AnyTransition {
        .modifier(
            active: PillArrivalModifier(opacity: 0, scale: 1, verticalOffset: 0),
            identity: PillArrivalModifier(opacity: 1, scale: 1, verticalOffset: 0)
        )
    }

    /// A row inserted while the pill is open: bounded grow/slide/blur in, plain fade out
    /// (the neighbours close the gap via the structural spring). Becomes a pure fade when
    /// the vocabulary has no geometry/blur.
    static func pillRow(_ motion: NotchAnimation.Motion, blurAllowed: Bool) -> AnyTransition {
        let rest = PillArrivalModifier(opacity: 1, scale: 1, verticalOffset: 0)
        return .asymmetric(
            insertion: .modifier(
                active: PillArrivalModifier(
                    opacity: 0,
                    scale: motion.rowArrivalScale,
                    verticalOffset: motion.rowArrivalOffsetY,
                    blur: blurAllowed ? motion.rowArrivalBlur : 0
                ),
                identity: rest
            ),
            removal: .modifier(
                active: PillArrivalModifier(
                    opacity: 0, scale: 1, verticalOffset: 0,
                    blur: blurAllowed ? motion.rowRemovalBlur : 0
                ),
                identity: rest
            )
        )
    }

    /// The compact wings handing over to the expanded content: shrink + blur + fade out
    /// (driven by the transaction's `contentOut`), plain fade in on the way back.
    static func pillWingsLeave(_ motion: NotchAnimation.Motion, blurAllowed: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity,
            // Its own animation: with snapping geometry the shared transaction carries none
            // (the shape snaps), and the wings would vanish before the content has faded in.
            removal: AnyTransition.modifier(
                active: PillArrivalModifier(
                    opacity: 0,
                    scale: motion.compactLeaveScale,
                    verticalOffset: 0,
                    blur: blurAllowed ? motion.compactLeaveBlur : 0
                ),
                identity: PillArrivalModifier(opacity: 1, scale: 1, verticalOffset: 0)
            )
            .animation(motion.contentOut)
        )
    }
}

extension AnyTransition {
    /// A collapsed-wing indicator swapping with another: the newcomer scales up from
    /// `wingSwapScaleIn` while fading in (driven by the wing's own `motion.wing` animation),
    /// the leaver shrinks to `wingSwapScaleOut` and fades over the fast exit curve. Both
    /// scale about the centre. Pure fades when the vocabulary has no geometry (Reduce Motion).
    static func pillWing(_ motion: NotchAnimation.Motion, blurAllowed: Bool) -> AnyTransition {
        let rest = PillArrivalModifier(opacity: 1, scale: 1, verticalOffset: 0, anchor: .center)
        let blur = blurAllowed ? motion.wingSwapBlur : 0
        return .asymmetric(
            insertion: .modifier(
                active: PillArrivalModifier(
                    opacity: 0, scale: motion.wingSwapScaleIn, verticalOffset: 0,
                    blur: blur, anchor: .center
                ),
                identity: rest
            ),
            removal: AnyTransition
                .modifier(
                    active: PillArrivalModifier(
                        opacity: 0, scale: motion.wingSwapScaleOut, verticalOffset: 0,
                        blur: blur, anchor: .center
                    ),
                    identity: rest
                )
                .animation(motion.contentOut)
        )
    }
}

// MARK: - Now-playing motion helpers

/// How often a client-side progress readout needs to redraw.
enum PillProgressCadence {
    /// The longest interval that still moves the fill by at most half a point per tick,
    /// never below `minimum` (the vocabulary's floor: 1/15s, or 1s under Reduce Motion) and
    /// never above one second. A 196pt bar over a 4-minute track needs ~0.6s, a 25-minute
    /// timer 1s; only short clips approach the 15 fps floor.
    static func interval(
        barWidth: CGFloat,
        duration: TimeInterval,
        minimum: TimeInterval = 1.0 / 15.0
    ) -> TimeInterval {
        guard barWidth > 0, duration > 0, barWidth.isFinite, duration.isFinite else { return 1 }
        let pointsPerSecond = Double(barWidth) / duration
        return min(1.0, max(minimum, 0.5 / pointsPerSecond))
    }
}

extension AnyTransition {
    /// Track-change text swap: the outgoing line fades up and out quickly (`contentOut`,
    /// 120ms) while the incoming line rises into place after a short delay (`swap`), both
    /// with a touch of blur. `delay` staggers the second line behind the first. Collapses
    /// to a plain crossfade when the vocabulary has no offset/blur (Reduce Motion).
    static func pillBlurSlide(
        _ motion: NotchAnimation.Motion, blurAllowed: Bool, secondLine: Bool = false
    ) -> AnyTransition {
        let rest = PillArrivalModifier(opacity: 1, scale: 1, verticalOffset: 0)
        let blur = blurAllowed ? motion.trackSwapBlur : 0
        return .asymmetric(
            insertion: AnyTransition
                .modifier(
                    active: PillArrivalModifier(
                        opacity: 0, scale: 1, verticalOffset: motion.trackSwapOffset, blur: blur
                    ),
                    identity: rest
                )
                .animation(motion.swap.delay(
                    motion.trackSwapDelay + (secondLine ? motion.trackSwapLineLag : 0)
                )),
            removal: AnyTransition
                .modifier(
                    active: PillArrivalModifier(
                        opacity: 0, scale: 1, verticalOffset: -motion.trackSwapOffset, blur: blur
                    ),
                    identity: rest
                )
                .animation(motion.contentOut)
        )
    }
}
