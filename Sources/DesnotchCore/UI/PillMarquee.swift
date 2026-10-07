import SwiftUI

/// Pure plan for scrolling a long title: how far it travels and how long each phase takes.
/// Kept separate from the view so the decisions (does it scroll at all, when may it run)
/// are unit-testable.
struct MarqueePlan: Equatable {
    /// Scroll speed in points per second.
    static let speed: CGFloat = 28
    /// Rest at the start before scrolling (the user reads the beginning first).
    static let startDelay: TimeInterval = 1.2
    /// Rest at the end before returning.
    static let endHold: TimeInterval = 0.9
    /// Fade-out/reset/fade-in back to the start.
    static let returnFade: TimeInterval = 0.25
    /// Passes per expansion, then it rests at the start: finite, never a loop.
    static let maxPasses = 2
    /// Overflow at or below this is not worth scrolling (the fade hides it).
    static let minimumOverflow: CGFloat = 4
    /// Width of the soft fade at each scrolling edge.
    static let edgeFade: CGFloat = 10

    /// How far past the container the text extends (points).
    let overflow: CGFloat

    var travel: TimeInterval { TimeInterval(overflow / Self.speed) }

    /// One full pass: start rest, travel, end hold, return fade.
    var cycleDuration: TimeInterval { Self.startDelay + travel + Self.endHold + Self.returnFade }

    /// nil when the text fits (or either width is unusable).
    static func make(textWidth: CGFloat, containerWidth: CGFloat) -> MarqueePlan? {
        guard textWidth.isFinite, containerWidth.isFinite, textWidth > 0, containerWidth > 0 else {
            return nil
        }
        let overflow = textWidth - containerWidth
        return overflow > minimumOverflow ? MarqueePlan(overflow: overflow) : nil
    }

    /// The marquee may only animate while the pill is fully expanded and visible, and only
    /// when motion is allowed. Everything else (collapsed, collapsing, expanding, Reduce
    /// Motion) rests at the start.
    static func shouldRun(plan: MarqueePlan?, expanded: Bool, allowsMotion: Bool) -> Bool {
        plan != nil && expanded && allowsMotion
    }
}

/// One line of text that scrolls to reveal its overflow while `isActive`, and otherwise
/// rests at its start behind a soft trailing fade. With motion suppressed (`allowsScroll`
/// false) it is a plain truncated line instead - the caller supplies the full text through
/// help/accessibility.
///
/// Costs nothing at rest: the only animation is a finite, generation-guarded sequence of
/// `withAnimation` steps (at most `MarqueePlan.maxPasses`), the scrolling text is rasterized
/// once (`drawingGroup`) and only its texture translates, and every step is cancelled the
/// moment `isActive` flips or the view disappears.
struct PillMarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let lineHeight: CGFloat
    let isActive: Bool
    let allowsScroll: Bool
    let fadeAnimation: Animation

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrolled = false
    @State private var atEnd = false
    @State private var returning = false
    @State private var generation = 0

    private var plan: MarqueePlan? {
        allowsScroll ? MarqueePlan.make(textWidth: textWidth, containerWidth: containerWidth) : nil
    }

    private var shouldRun: Bool {
        MarqueePlan.shouldRun(plan: plan, expanded: isActive, allowsMotion: allowsScroll)
    }

    /// Everything that restarts the sequence, as one value. `onChange` hands the NEW value to
    /// its closure; reading `isActive`/`plan` through `self` inside the closure would see the
    /// previous render's copy of these value-type properties and never start the scroll.
    private struct RunState: Equatable {
        let shouldRun: Bool
        let plan: MarqueePlan?
        let text: String
    }

    private var runState: RunState {
        RunState(shouldRun: shouldRun, plan: plan, text: text)
    }

    var body: some View {
        // `Color.clear` owns the layout (full proposed width, fixed line height); the text
        // lives in an overlay so its natural width can never feed back into the container
        // measurement. Widths are written straight into local state from `GeometryReader`
        // callbacks: preference keys do not propagate reliably out of a subtree whose
        // content switches branches (verified in a headless render), and this is local
        // state only - it never touches the panel's size key.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: lineHeight)
            .overlay(alignment: .leading) { line }
            .clipped()
            .mask {
                if plan != nil {
                    edgeMask
                } else {
                    Rectangle()
                }
            }
            .animation(fadeAnimation, value: scrolled)
            .animation(fadeAnimation, value: atEnd)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { containerWidth = $0 }
                }
            )
            .background(
                // Natural single-line width of the text, measured off-screen.
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { textWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { textWidth = $0 }
                        }
                    )
            )
            .onAppear { restart(runState) }
            .onDisappear { stop() }
            .onChange(of: runState) { restart($0) }
    }

    @ViewBuilder
    private var line: some View {
        if plan != nil {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .drawingGroup()
                .offset(x: offset)
                .opacity(returning ? 0 : 1)
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Soft edges only while the text is overflowing: nothing at the leading edge until it
    /// has scrolled, nothing at the trailing edge once it has reached the end.
    private var edgeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [scrolled ? .clear : .black, .black],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: MarqueePlan.edgeFade)
            Rectangle().fill(Color.black)
            LinearGradient(
                colors: [.black, atEnd ? .black : .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: MarqueePlan.edgeFade)
        }
    }

    private func stop() {
        generation += 1
        reset()
    }

    /// Back to the resting state without animating (the content is invisible or about to
    /// be replaced when this runs).
    private func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            scrolled = false
            atEnd = false
            returning = false
        }
    }

    private func restart(_ state: RunState) {
        generation += 1
        reset()
        guard state.shouldRun, let plan = state.plan else { return }
        runPass(1, plan: plan, generation: generation)
    }

    /// One pass: rest, scroll, hold, fade back. Every step re-checks the generation so a
    /// collapse, track change or privacy toggle cancels the rest of the sequence.
    private func runPass(_ pass: Int, plan: MarqueePlan, generation: Int) {
        func after(_ delay: TimeInterval, _ step: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == self.generation else { return }
                step()
            }
        }
        let scrollStart = MarqueePlan.startDelay
        let scrollEnd = scrollStart + plan.travel
        let fadeOut = scrollEnd + MarqueePlan.endHold
        let fadeBack = fadeOut + MarqueePlan.returnFade / 2

        after(scrollStart) {
            scrolled = true
            withAnimation(.linear(duration: plan.travel)) { offset = -plan.overflow }
        }
        after(scrollEnd) { atEnd = true }
        after(fadeOut) {
            withAnimation(.easeIn(duration: MarqueePlan.returnFade / 2)) { returning = true }
        }
        after(fadeBack) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                offset = 0
                scrolled = false
                atEnd = false
            }
            withAnimation(.easeOut(duration: MarqueePlan.returnFade / 2)) { returning = false }
        }
        after(plan.cycleDuration) {
            if pass < MarqueePlan.maxPasses {
                runPass(pass + 1, plan: plan, generation: generation)
            }
        }
    }
}
