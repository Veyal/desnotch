import SwiftUI

// Small shared building blocks for the pill's sections and wings. Each takes the resolved
// `NotchAnimation.Motion` (and the Reduce Transparency flag) from the pill instead of reading
// the environment itself, so one decision governs everything. Nothing here loops: every
// sequence is finite, generation-guarded, and ends at rest.

// MARK: - Chip

/// A small status capsule (agent state, count): tinted text on a 16% tint of the shell.
struct PillChip: View {
    let text: String
    let tint: PillPalette.Swatch
    var reduceTransparency = false

    var body: some View {
        Text(text)
            .font(PillTextStyle.captionStrong.font)
            .foregroundStyle(tint.color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.fill(alpha: 0.16, reduceTransparency: reduceTransparency))
            )
    }
}

// MARK: - One-shot pop

/// Scales its content up to `peak` and springs back when `trigger` changes: a single
/// acknowledgement, never repeated. `peak == 1` (Reduce Motion) makes it inert.
struct PillPop: ViewModifier {
    let trigger: Int
    let peak: CGFloat
    let motion: NotchAnimation.Motion

    @State private var popped = false
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(popped ? peak : 1)
            .onChange(of: trigger) { _ in
                guard peak != 1 else { return }
                generation += 1
                let token = generation
                withAnimation(motion.press) { popped = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + motion.pressHold) {
                    guard token == generation else { return }
                    withAnimation(motion.release) { popped = false }
                }
            }
            .onDisappear { generation += 1 }
    }
}

extension View {
    func pillPop(trigger: Int, peak: CGFloat, motion: NotchAnimation.Motion) -> some View {
        modifier(PillPop(trigger: trigger, peak: peak, motion: motion))
    }
}

// MARK: - Ripple

/// A ring that expands and fades `passes` times, then rests invisible. The finite attention
/// pulse: it plays when `trigger` increases (or once on appear for a fresh event) and never
/// loops, so an idle pill runs no animation. Every step is generation-guarded, so a new
/// trigger or disappearing restarts or cancels it cleanly. Decorative: hidden from VoiceOver.
struct PillRipple: View {
    enum Outline { case circle, capsule }

    let trigger: Int
    let passes: Int
    let duration: TimeInterval
    let gap: TimeInterval
    /// Scale the ring reaches (it starts at 0.8).
    let growth: CGFloat
    let tint: Color
    var lineWidth: CGFloat = 1.5
    var outline: Outline = .circle
    /// Play once when first shown if `trigger > 0` (a fresh event that opened the pill).
    var playsOnAppear = false

    @State private var progress: CGFloat = 0
    @State private var armed = false
    @State private var lastTrigger = 0
    @State private var generation = 0

    private static let startScale: CGFloat = 0.8

    var body: some View {
        ring
            .scaleEffect(Self.startScale + (growth - Self.startScale) * progress)
            .opacity(armed ? 0.6 * Double(1 - progress) : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                lastTrigger = trigger
                if playsOnAppear, trigger > 0 { play() }
            }
            .onChange(of: trigger) { new in
                if new > lastTrigger { play() }
                lastTrigger = new
            }
            .onDisappear { generation += 1 }
    }

    @ViewBuilder
    private var ring: some View {
        switch outline {
        case .circle: Circle().stroke(tint, lineWidth: lineWidth)
        case .capsule: Capsule(style: .continuous).stroke(tint, lineWidth: lineWidth)
        }
    }

    private func play() {
        generation += 1
        guard passes > 0, duration > 0 else { return }
        runPass(1, generation: generation)
    }

    private func runPass(_ pass: Int, generation token: Int) {
        guard token == generation else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            progress = 0
            armed = true
        }
        // Start the expansion on the next turn so the reset above is a real frame.
        DispatchQueue.main.async {
            guard token == generation else { return }
            withAnimation(.easeOut(duration: duration)) { progress = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard token == generation else { return }
            withTransaction(reset) {
                armed = false
                progress = 0
            }
            if pass < passes {
                DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
                    runPass(pass + 1, generation: token)
                }
            }
        }
    }
}

// MARK: - Redaction

extension View {
    /// A redacted user string crossfades when privacy mode toggles. Opacity only - a blur
    /// would sample the pre-redaction pixels, which is exactly what privacy mode hides.
    func pillRedactionFade(_ privacy: Bool, motion: NotchAnimation.Motion) -> some View {
        contentTransition(.opacity)
            .animation(motion.swap, value: privacy)
    }
}

// MARK: - Landing / copy highlight

/// A row highlight that is lit while `fresh` and fades out afterwards: a freshly dropped
/// file or copied clip, "this is the row that changed". It fades in on the quick curve and
/// out on `landingFlashOut`; a row inserted already-fresh simply starts lit. Reduce Motion
/// resolves `landingFlashPeak` to 0, which turns it off (the row's own arrival fade remains).
struct PillLandingFlash: ViewModifier {
    let fresh: Bool
    let motion: NotchAnimation.Motion
    var tint: PillPalette.Swatch = PillPalette.white
    /// Overrides `motion.landingFlashPeak` (still suppressed when that is 0).
    var peak: Double?
    var reduceTransparency = false

    private var level: Double {
        guard motion.landingFlashPeak > 0 else { return 0 }
        return fresh ? (peak ?? motion.landingFlashPeak) : 0
    }

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: PillRadius.row, style: .continuous)
                .fill(tint.fill(alpha: level, reduceTransparency: reduceTransparency))
                .padding(.horizontal, -6)
                .padding(.vertical, -2)
                .animation(fresh ? motion.fade : motion.landingFlashOut, value: fresh)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    func pillLandingFlash(
        _ fresh: Bool,
        motion: NotchAnimation.Motion,
        tint: PillPalette.Swatch = PillPalette.white,
        peak: Double? = nil,
        reduceTransparency: Bool = false
    ) -> some View {
        modifier(PillLandingFlash(
            fresh: fresh, motion: motion, tint: tint, peak: peak,
            reduceTransparency: reduceTransparency
        ))
    }
}

// MARK: - Timer ring

/// A check mark that can be drawn with `trim`.
struct PillCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.24))
        return path
    }
}

/// The focus timer's ring, shared by the expanded row (32pt) and the collapsed wing (14pt).
/// One persistent view: running, paused and completed morph into each other (tint
/// crossfades, the trim fills to 1 on completion, the check draws in) instead of the row
/// being replaced. The ring advances once a second (a short run glides linearly between ticks)
/// (no per-frame timeline); under Reduce Motion it steps. A completion ripples a finite
/// number of times. Decorative: VoiceOver reads the row/wing labels.
struct PillTimerRing: View {
    enum Phase: Equatable { case running, paused, completed }

    let phase: Phase
    /// Elapsed fraction 0...1.
    let progress: Double
    var size: CGFloat = 32
    var lineWidth: CGFloat = 3
    var glyphSize: CGFloat = 12
    /// Total length of the run, used only to decide whether the ring's per-second step is
    /// big enough to be worth gliding (0 = never glide).
    var duration: TimeInterval = 0
    let motion: NotchAnimation.Motion
    var reduceTransparency = false
    var increasedContrast = false
    /// Increases when a run completes (drives the ripple).
    var completionTrigger = 0
    /// The completion just happened (the pill opened because of it): ripple and draw on appear.
    var isFreshCompletion = false

    @State private var checkDrawn = false

    // MARK: Pure helpers

    static func tint(for phase: Phase) -> PillPalette.Swatch {
        switch phase {
        case .running: return PillPalette.cyan
        case .paused: return PillPalette.amber
        case .completed: return PillPalette.green
        }
    }

    /// Fraction of the ring that is filled: a completed run is always full.
    static func displayedProgress(phase: Phase, progress: Double) -> Double {
        guard phase != .completed else { return 1 }
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    /// Elapsed fraction from a remaining time and the run's duration.
    static func progress(remaining: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, duration.isFinite, remaining.isFinite else { return 0 }
        return min(1, max(0, 1 - remaining / duration))
    }

    /// A one-second linear glide between ticks only pays off when the ring moves at least
    /// half a point per second; a 25-minute run on a 32pt ring moves ~0.06pt/s, and gliding
    /// it would keep the display link at 60 fps for nothing. Longer runs simply step.
    static func glides(duration: TimeInterval, size: CGFloat, lineWidth: CGFloat) -> Bool {
        guard duration > 0, duration.isFinite, size > lineWidth else { return false }
        let circumference = Double.pi * Double(size - lineWidth)
        return circumference / duration >= 0.5
    }

    /// Increase Contrast thickens the stroke by one point.
    static func strokeWidth(base: CGFloat, increasedContrast: Bool) -> CGFloat {
        increasedContrast ? base + 1 : base
    }

    // MARK: View

    var body: some View {
        let tint = Self.tint(for: phase).color
        let shown = Self.displayedProgress(phase: phase, progress: progress)
        let width = Self.strokeWidth(base: lineWidth, increasedContrast: increasedContrast)
        ZStack {
            Circle()
                .stroke(
                    reduceTransparency ? PillPalette.opaqueWhite(0.14) : Color.white.opacity(0.14),
                    lineWidth: width
                )
            Circle()
                .trim(from: 0, to: CGFloat(shown))
                .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(trimAnimation, value: shown)
            glyph(tint: tint)
            PillRipple(
                trigger: completionTrigger,
                passes: motion.attentionPulseCount,
                duration: motion.attentionPulseDuration,
                gap: motion.attentionPulseGap,
                growth: motion.ringPulseScale,
                tint: PillPalette.green.color,
                playsOnAppear: isFreshCompletion
            )
        }
        .frame(width: size, height: size)
        .animation(motion.swap, value: phase)
        .accessibilityHidden(true)
        .onAppear {
            if phase == .completed { drawCheck(animated: isFreshCompletion) }
        }
        .onChange(of: phase) { new in
            if new == .completed {
                drawCheck(animated: true)
            } else {
                checkDrawn = false
            }
        }
    }

    private var trimAnimation: Animation? {
        // Between ticks a short run's ring glides (linear, one second); it never needs a
        // timeline finer than the 1 Hz tick that moves it. Long runs and Reduce Motion
        // (no geometry allowance) step instead, so a running timer is not a 60 fps animation.
        if phase == .running {
            let glides = motion.allowsGeometry
                && Self.glides(duration: duration, size: size, lineWidth: lineWidth)
            return glides ? .linear(duration: 1) : nil
        }
        return motion.swap
    }

    @ViewBuilder
    private func glyph(tint: Color) -> some View {
        ZStack {
            switch phase {
            case .running:
                Image(systemName: "timer")
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(tint)
                    .transition(.opacity)
            case .paused:
                Image(systemName: "pause.fill")
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(tint)
                    .transition(.opacity)
            case .completed:
                PillCheckmarkShape()
                    .trim(from: 0, to: checkDrawn ? 1 : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: max(1.5, glyphSize / 6), lineCap: .round, lineJoin: .round))
                    .frame(width: glyphSize, height: glyphSize)
                    .transition(.opacity)
            }
        }
    }

    private func drawCheck(animated: Bool) {
        if animated, motion.checkDrawDuration > 0 {
            withAnimation(.easeOut(duration: motion.checkDrawDuration)) { checkDrawn = true }
        } else {
            checkDrawn = true
        }
    }
}

// MARK: - Checkbox

/// The reminders row's round checkbox. Completing fills it green with a tactile pop and a
/// check; the fill is an opacity/colour change, so it reads under Reduce Motion too.
struct PillCheckbox: View {
    let completed: Bool
    let motion: NotchAnimation.Motion
    var reduceTransparency = false

    static let diameter: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(PillPalette.slateGray, lineWidth: 1.5)
                .opacity(completed ? 0 : 1)
            Circle()
                .fill(PillPalette.green.color)
                .opacity(completed ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.black)
                .opacity(completed ? 1 : 0)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .animation(motion.swap, value: completed)
        .pillPop(trigger: completed ? 1 : 0, peak: motion.popScale, motion: motion)
        .accessibilityHidden(true)
    }
}

// MARK: - Switch

/// The privacy row's switch: a 30x18 capsule with a knob that slides with the tactile
/// release spring (snaps under Reduce Motion). The state is also shown as the text
/// "On"/"Off" beside it, so colour is never the only signal.
struct PillSwitch: View {
    let isOn: Bool
    let motion: NotchAnimation.Motion
    var reduceTransparency = false

    static let size = CGSize(width: 30, height: 18)
    static let knobDiameter: CGFloat = 14

    /// Knob centre offset from the track centre.
    static func knobOffset(isOn: Bool) -> CGFloat {
        let travel = (size.width - knobDiameter - 4) / 2
        return isOn ? travel : -travel
    }

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(isOn
                    ? PillPalette.cyan.color
                    : (reduceTransparency ? PillPalette.opaqueWhite(0.18) : Color.white.opacity(0.18)))
            Circle()
                .fill(Color.white)
                .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                .offset(x: Self.knobOffset(isOn: isOn))
                .animation(motion.allowsGeometry ? motion.release : nil, value: isOn)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(motion.swap, value: isOn)
        .accessibilityHidden(true)
    }
}

// MARK: - Battery glyph

/// A custom 22x10 battery whose fill width is the charge, so the level reads at a glance
/// and animates between values without swapping SF Symbols. Plug/unplug pops the bolt in and
/// sweeps one soft highlight across the fill, once. Decorative: the row carries the label.
struct PillBatteryGlyph: View {
    let percent: Int
    let isCharging: Bool
    let motion: NotchAnimation.Motion
    var reduceTransparency = false

    static let bodySize = CGSize(width: 22, height: 10)
    static let inset: CGFloat = 1.5
    static var innerWidth: CGFloat { bodySize.width - inset * 2 }
    static var innerHeight: CGFloat { bodySize.height - inset * 2 }

    @State private var sweep: CGFloat = 0
    @State private var sweeping = false
    @State private var generation = 0

    // MARK: Pure helpers

    static func fraction(percent: Int) -> CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100
    }

    /// Fill width for `percent`: proportional, but never a sliver too thin to see.
    static func fillWidth(percent: Int, inner: CGFloat) -> CGFloat {
        let clamped = min(max(percent, 0), 100)
        guard clamped > 0 else { return 0 }
        return max(2, inner * fraction(percent: clamped))
    }

    /// Green while charging, red at 20% or below, neutral otherwise.
    static func tint(percent: Int, isCharging: Bool) -> PillPalette.Swatch {
        if isCharging { return PillPalette.green }
        return percent <= 20 ? PillPalette.red : PillPalette.mist
    }

    /// The bolt sits on the fill, so it is dark when the fill is under it and light when not.
    static func boltIsDark(percent: Int) -> Bool { percent >= 50 }

    var body: some View {
        let tint = Self.tint(percent: percent, isCharging: isCharging).color
        let width = Self.fillWidth(percent: percent, inner: Self.innerWidth)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                .frame(width: Self.bodySize.width, height: Self.bodySize.height)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: width, height: Self.innerHeight)
                .overlay(alignment: .leading) { sweepBand(fillWidth: width) }
                .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                .padding(.leading, Self.inset)
                .animation(motion.swap, value: percent)
            RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                .fill(Color.white.opacity(0.5))
                .frame(width: 1.5, height: 4)
                .offset(x: Self.bodySize.width + 0.5)
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Self.boltIsDark(percent: percent) ? Color.black : Color.white)
                    .frame(width: Self.bodySize.width)
                    .transition(boltTransition)
            }
        }
        .frame(width: Self.bodySize.width + 2, height: Self.bodySize.height, alignment: .leading)
        .animation(motion.allowsGeometry ? motion.release : motion.swap, value: isCharging)
        .onChange(of: isCharging) { _ in playSweep() }
        .onDisappear { generation += 1 }
        .accessibilityHidden(true)
    }

    private var boltTransition: AnyTransition {
        motion.allowsGeometry
            ? .opacity.combined(with: .scale(scale: 0.4))
            : .opacity
    }

    @ViewBuilder
    private func sweepBand(fillWidth: CGFloat) -> some View {
        if sweeping {
            LinearGradient(
                colors: [.clear, Color.white.opacity(reduceTransparency ? 0.5 : 0.55), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 8)
            .offset(x: -8 + (fillWidth + 8) * sweep)
        }
    }

    private func playSweep() {
        guard motion.allowsGeometry, motion.sweepDuration > 0 else { return }
        generation += 1
        let token = generation
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            sweep = 0
            sweeping = true
        }
        DispatchQueue.main.async {
            guard token == generation else { return }
            withAnimation(.easeInOut(duration: motion.sweepDuration)) { sweep = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.sweepDuration + 0.02) {
            guard token == generation else { return }
            withTransaction(reset) { sweeping = false }
        }
    }
}
