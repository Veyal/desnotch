import AppKit
import SwiftUI

extension VoiceCardLayout {
    static var literalNSFont: NSFont {
        .monospacedSystemFont(ofSize: literalFontSize, weight: .regular)
    }

    static var literalFont: Font {
        .system(size: literalFontSize, design: .monospaced)
    }
}

struct VoiceSectionActions {
    var stop: () -> Void
    var resume: () -> Void
    var cancel: () -> Void
    var approve: (String) -> Void
    var deny: (String) -> Void

    static let none = VoiceSectionActions(
        stop: {}, resume: {}, cancel: {}, approve: { _ in }, deny: { _ in }
    )
}

@MainActor
struct VoiceMeter: View {
    static let barCount = VoiceLimits.meterBars
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 1.5
    static let minBarHeight: CGFloat = 3
    static let maxBarHeight: CGFloat = 12
    static let totalWidth: CGFloat = 16

    let levels: [Float]
    let motion: NotchAnimation.Motion

    init(levels: [Float], motion: NotchAnimation.Motion) {
        self.levels = levels
        self.motion = motion
    }

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                let level = barLevel(index)
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: Self.barWidth, height: barHeight(level))
                    .animation(motion.allowsGeometry ? motion.direct : nil, value: level)
            }
        }
        .frame(width: Self.totalWidth, height: Self.maxBarHeight, alignment: .center)
        .accessibilityHidden(true)
    }

    private func barLevel(_ index: Int) -> Float {
        if !motion.allowsGeometry {
            let pattern: [Float] = [0.4, 0.7, 1.0, 0.7, 0.4]
            return index < pattern.count ? pattern[index] : 0
        }
        return index < levels.count ? levels[index] : 0
    }

    private func barHeight(_ level: Float) -> CGFloat {
        let clamped = min(1, max(0, level))
        return Self.minBarHeight + CGFloat(clamped) * (Self.maxBarHeight - Self.minBarHeight)
    }
}

@MainActor
struct VoiceLiteralBlock: View {
    static let horizontalPadding = PillSpace.s
    static let verticalPadding = PillSpace.xs

    let text: String
    var reduceTransparency = false
    var increasedContrast = false

    var body: some View {
        Text(text)
            .font(VoiceCardLayout.literalFont)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: PillRadius.row, style: .continuous)
                    .fill(PillSurface.highlight(
                        base: 0.08,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: increasedContrast
                    ))
            )
    }
}

@MainActor
struct VoiceApproveButton: View {
    let spec: VoiceButtonSpec
    let presentedNonce: String
    let actions: VoiceSectionActions
    let motion: NotchAnimation.Motion
    let increasedContrast: Bool

    @GestureState private var isPressing = false
    @State private var progress: CGFloat = 0
    @Environment(\.isFocused) private var isFocused

    /// Re-checks the card that is on screen. A gesture is not a button, so a disabled
    /// spec or a nonce from a previous card must not be able to approve.
    static func commit(
        spec: VoiceButtonSpec, presentedNonce: String, actions: VoiceSectionActions
    ) -> Bool {
        guard spec.isEnabled, let nonce = spec.nonce, nonce == presentedNonce else { return false }
        actions.approve(nonce)
        return true
    }

    var body: some View {
        let labeled = content
            .id(presentedNonce)
        if spec.isEnabled {
            labeled
                .gesture(hold)
                .onChange(of: isPressing) { pressing in
                    guard motion.allowsGeometry else { return }
                    if pressing {
                        withAnimation(.linear(duration: motion.approveHoldDuration)) {
                            progress = 1
                        }
                    } else {
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) { progress = 0 }
                    }
                }
                .accessibilityLabel("Approve, hold to confirm")
                .accessibilityAddTraits(.isButton)
        } else {
            labeled
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(spec.title)
        }
    }

    private var hold: some Gesture {
        LongPressGesture(minimumDuration: motion.approveHoldDuration)
            .updating($isPressing) { value, state, _ in
                state = value
            }
            .onEnded { _ in
                _ = Self.commit(spec: spec, presentedNonce: presentedNonce, actions: actions)
            }
    }

    private var content: some View {
        Text(spec.title)
            .font(PillTextStyle.body.font)
            .lineLimit(1)
            .frame(minHeight: 24)
            .padding(.horizontal, PillSpace.s)
            .background(
                Circle()
                    .trim(from: 0, to: ringTrim)
                    .stroke(VoiceSectionChrome.color(for: .amber), lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                    .opacity(ringOpacity)
            )
            .pillFocusRing(
                RoundedRectangle(cornerRadius: PillRadius.control, style: .continuous),
                isFocused: isFocused,
                increasedContrast: increasedContrast
            )
    }

    private var ringTrim: CGFloat {
        if motion.allowsGeometry { return progress }
        return isPressing ? 1 : 0
    }

    private var ringOpacity: Double {
        if motion.allowsGeometry { return progress > 0 || isPressing ? 1 : 0 }
        return isPressing ? 0.45 : 0
    }
}

@MainActor
struct VoiceSectionView: View {
    let presentation: VoiceSectionPresentation
    let levels: [Float]
    let width: CGFloat
    let motion: NotchAnimation.Motion
    let contrast: ColorSchemeContrast
    let reduceTransparency: Bool
    let actions: VoiceSectionActions

    var body: some View {
        VStack(alignment: .leading, spacing: PillSpace.xs) {
            header
            ForEach(Array(presentation.bodyLines.enumerated()), id: \.offset) { _, line in
                bodyText(line)
            }
            if presentation.showsMeter {
                VoiceMeter(levels: levels, motion: motion)
            }
            if let countdown = presentation.countdown {
                VoiceCountdownBar(
                    countdown: countdown,
                    tint: VoiceSectionChrome.color(for: presentation.tint),
                    motion: motion
                )
            }
            if !presentation.chips.isEmpty {
                chipRow(presentation.chips, tint: PillPalette.mist)
            }
            if let card = presentation.card {
                cardBody(card)
            }
            if !presentation.buttons.isEmpty {
                buttonRow
            }
        }
        .padding(.vertical, PillSpace.xs)
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var header: some View {
        HStack(spacing: PillSpace.xs) {
            if let glyph = presentation.wingLeft {
                ZStack {
                    if presentation.card != nil {
                        PillRipple(
                            trigger: 1,
                            passes: motion.attentionPulseCount,
                            duration: motion.attentionPulseDuration,
                            gap: motion.attentionPulseGap,
                            growth: motion.ringPulseScale,
                            tint: PillPalette.amber.color,
                            playsOnAppear: true
                        )
                    }
                    Image(systemName: glyph.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VoiceSectionChrome.color(for: presentation.tint))
                        .frame(width: 16, height: 16)
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            }
            Text(presentation.title)
                .font(PillTextStyle.bodyStrong.font)
                .lineLimit(presentation.titleLineLimit)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if presentation.showsCloudBadge {
                HStack(spacing: 3) {
                    Image(systemName: VoiceGlyph.cloud.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PillPalette.mist.color)
                    Text("Hermes")
                        .font(PillTextStyle.caption.font)
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func bodyText(_ line: VoiceBodyLine) -> some View {
        Text(line.text)
            .font(VoiceSectionChrome.font(for: line.emphasis).font)
            .lineLimit(line.lineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipRow(_ chips: [VoiceChipSpec], tint: PillPalette.Swatch) -> some View {
        HStack(spacing: PillSpace.xs) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                PillChip(text: chip.text, tint: tint, reduceTransparency: reduceTransparency)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }

    private func cardBody(_ card: VoiceCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: PillSpace.xs) {
            ViewThatFits(in: .horizontal) {
                riskRow(card, compact: false)
                riskRow(card, compact: true)
            }
            .frame(maxWidth: width, alignment: .leading)
            if card.requiresHold || card.summary != card.literal {
                Text(card.summary)
                    .font(PillTextStyle.body.font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VoiceLiteralBlock(
                text: card.literal,
                reduceTransparency: reduceTransparency,
                increasedContrast: contrast == .increased
            )
            if let note = card.note {
                Text(note)
                    .font(PillTextStyle.caption.font)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let hint = card.hint {
                Text(hint)
                    .font(PillTextStyle.caption.font)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func riskRow(_ card: VoiceCardPresentation, compact: Bool) -> some View {
        // Mist for T0/T1 and amber for T2 per the card table. T3 and T4 use amber,
        // the stronger swatch, because those tiers cannot be approved.
        let tierTint: PillPalette.Swatch = (card.tierLabel == "T0" || card.tierLabel == "T1")
            ? PillPalette.mist
            : PillPalette.amber
        let totalRisks = card.riskWords.count + card.riskOverflow
        return HStack(spacing: PillSpace.xs) {
            PillChip(text: card.tierLabel, tint: tierTint, reduceTransparency: reduceTransparency)
                .lineLimit(1)
            if compact {
                if totalRisks > 0 {
                    PillChip(
                        text: totalRisks == 1 ? "1 risk" : "\(totalRisks) risks",
                        tint: PillPalette.amber,
                        reduceTransparency: reduceTransparency
                    )
                    .lineLimit(1)
                }
            } else {
                ForEach(Array(card.riskWords.enumerated()), id: \.offset) { _, word in
                    PillChip(text: word, tint: PillPalette.amber, reduceTransparency: reduceTransparency)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if card.riskOverflow > 0 {
                    PillChip(
                        text: "+\(card.riskOverflow)",
                        tint: PillPalette.amber,
                        reduceTransparency: reduceTransparency
                    )
                    .lineLimit(1)
                }
            }
        }
    }

    private var buttonRow: some View {
        HStack(spacing: PillSpace.s) {
            Spacer(minLength: 0)
            ForEach(Array(presentation.buttons.enumerated()), id: \.offset) { _, spec in
                button(spec)
            }
        }
    }

    @ViewBuilder
    private func button(_ spec: VoiceButtonSpec) -> some View {
        switch spec.role {
        case .approveHold:
            VoiceApproveButton(
                spec: spec,
                presentedNonce: spec.nonce ?? "",
                actions: actions,
                motion: motion,
                increasedContrast: contrast == .increased
            )
        case .stop, .cancel:
            Button {
                if spec.role == .stop {
                    actions.stop()
                } else {
                    actions.cancel()
                }
            } label: {
                Image(systemName: (spec.glyph ?? .stop).rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PillButtonStyle(role: .icon))
            .disabled(!spec.isEnabled)
            .accessibilityLabel(spec.title)
        case .resume, .deny, .approveClick:
            Button {
                switch spec.role {
                case .resume:
                    actions.resume()
                case .deny:
                    if let nonce = spec.nonce { actions.deny(nonce) }
                case .approveClick:
                    if let nonce = spec.nonce, spec.isEnabled { actions.approve(nonce) }
                default:
                    break
                }
            } label: {
                Text(spec.title)
                    .font(PillTextStyle.body.font)
                    .lineLimit(1)
                    .frame(minHeight: 24)
                    .padding(.horizontal, PillSpace.xs)
            }
            .buttonStyle(PillButtonStyle(role: .row))
            .disabled(!spec.isEnabled)
            .accessibilityLabel(spec.title)
        }
    }
}

@MainActor
private struct VoiceCountdownBar: View {
    let countdown: VoiceCountdown
    let tint: Color
    let motion: NotchAnimation.Motion

    @State private var fraction: Double = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.2))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, proxy.size.width * fraction))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
        .id(countdown.deadline)
        .onAppear { start() }
    }

    private func start() {
        let now = Date()
        let start = countdown.remainingFraction(now: now)
        if motion.allowsGeometry {
            fraction = start
            let remaining = max(0, countdown.deadline.timeIntervalSince(now))
            withAnimation(.linear(duration: remaining)) {
                fraction = 0
            }
        } else {
            fraction = start
        }
    }
}

enum VoiceSectionChrome {
    static func color(for tint: VoiceTint) -> Color {
        switch tint {
        case .neutral: return .white
        case .calm: return PillPalette.mist.color
        case .amber: return PillPalette.amber.color
        case .red: return PillPalette.red.color
        }
    }

    static func font(for emphasis: VoiceLineEmphasis) -> PillTextStyle {
        switch emphasis {
        case .primary: return .bodyStrong
        case .secondary: return .body
        case .caption: return .caption
        }
    }
}

@MainActor
struct VoiceSectionHost: View {
    @ObservedObject var model: VoiceSessionModel
    let privacyMode: Bool
    let width: CGFloat
    let motion: NotchAnimation.Motion
    let contrast: ColorSchemeContrast
    let reduceTransparency: Bool

    init(
        model: VoiceSessionModel,
        privacyMode: Bool,
        width: CGFloat,
        motion: NotchAnimation.Motion,
        contrast: ColorSchemeContrast,
        reduceTransparency: Bool
    ) {
        self.model = model
        self.privacyMode = privacyMode
        self.width = width
        self.motion = motion
        self.contrast = contrast
        self.reduceTransparency = reduceTransparency
    }

    var body: some View {
        let snapshot = VoiceSectionSnapshot(model: model)
        let presentation = VoiceSectionPresentation(snapshot, privacyMode: privacyMode, now: Date())
        VoiceSectionView(
            presentation: presentation,
            levels: model.levels,
            width: width,
            motion: motion,
            contrast: contrast,
            reduceTransparency: reduceTransparency,
            actions: VoiceSectionActions(
                stop: { model.stopAll() },
                resume: { model.resume() },
                cancel: { model.cancelReview() },
                approve: { model.approve(nonce: $0) },
                deny: { model.deny(nonce: $0) }
            )
        )
    }
}
