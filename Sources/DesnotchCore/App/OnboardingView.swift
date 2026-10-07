import SwiftUI

/// A short, privacy-safe introduction to the parts of desnotch that are easy to miss.
///
/// This view intentionally contains no live state or permission requests. It is safe to
/// present from the settings window and remains useful in previews and screenshots.
public struct OnboardingView: View {
    public var onOpenSettings: () -> Void
    public var onDone: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(onOpenSettings: @escaping () -> Void = {}, onDone: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    GuideCard(
                        symbol: "hand.point.up.left.fill",
                        tint: .cyan,
                        title: "Hover to see more",
                        detail: "The notch stays quiet until you move over it. The expanded view brings your active sections together in one place."
                    )
                    GuideCard(
                        symbol: "speaker.wave.2.fill",
                        tint: .orange,
                        title: "Scroll to change volume",
                        detail: "Place the pointer over the notch and scroll up or down to adjust your default output."
                    )
                    GuideCard(
                        symbol: "timer",
                        tint: .cyan,
                        title: "Start a focus timer",
                        detail: "Use Focus Timer in the status menu for a 5, 15, 25, or 50 minute session. Pause or finish it from the notch."
                    )
                    GuideCard(
                        symbol: "tray.and.arrow.down.fill",
                        tint: .green,
                        title: "Drop files into the tray",
                        detail: "Drag a file onto the notch for a small shelf. Click to open, drag it back out, or right-click to reveal, copy, share, or remove it."
                    )
                    GuideCard(
                        symbol: "keyboard.fill",
                        tint: .indigo,
                        title: "Keyboard and VoiceOver",
                        detail: "Choose Show Notch in the status menu to hold the notch open, or turn on the \(HotKeyBinding.default.displayString) shortcut in Settings. The status menu also lists the next meeting, reminders, agents, and battery, so everything is reachable without hovering."
                    )
                    GuideCard(
                        symbol: "checklist",
                        tint: .purple,
                        title: "Turn on only what helps",
                        detail: "Reminders and the clipboard pocket are optional and off by default. Configure them in Settings when you need them."
                    )
                    GuideCard(
                        symbol: "wand.and.rays",
                        tint: .teal,
                        title: "Motion that follows you",
                        detail: "The notch springs open and fades its sections in. Choose Subtle, Dynamic, or Minimal in Settings; macOS Reduce Motion always wins and keeps only short fades."
                    )
                    GuideCard(
                        symbol: "eye.slash.fill",
                        tint: .pink,
                        title: "Privacy mode for sharing",
                        detail: "Hide titles, names, previews, and filenames before screen sharing. Toggle it from the status menu."
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()
                .opacity(0.35)
            footer
        }
        .frame(width: 360, height: 560)
        // Solid system background: no gradient, so Reduce Transparency and Increase Contrast
        // need no special case here.
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.onboardingEmphasis, OnboardingEmphasis(
            solidSurface: reduceTransparency, strongEdge: contrast == .increased
        ))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A static miniature of the pill's silhouette: the same shape and solid black
            // as the real notch, so the first thing shown is the thing being introduced.
            NotchShape(topEar: 3, bottomRadius: 8)
                .fill(Color.black)
                .frame(width: 72, height: 18)
                .overlay(
                    NotchShape(topEar: 3, bottomRadius: 8)
                        .stroke(Color.primary.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 0.5)
                )
                .accessibilityHidden(true)
            Text("Make the notch yours")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text("A few useful shortcuts, always close at hand.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            Button("Open Settings…", action: onOpenSettings)
                .buttonStyle(.link)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 12)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Surface treatment for the guide cards, derived once from the accessibility environment.
private struct OnboardingEmphasis: Equatable {
    /// Reduce Transparency: opaque card fill instead of a translucent tint.
    var solidSurface = false
    /// Increase Contrast: a visibly stronger card edge.
    var strongEdge = false
}

private struct OnboardingEmphasisKey: EnvironmentKey {
    static let defaultValue = OnboardingEmphasis()
}

private extension EnvironmentValues {
    var onboardingEmphasis: OnboardingEmphasis {
        get { self[OnboardingEmphasisKey.self] }
        set { self[OnboardingEmphasisKey.self] = newValue }
    }
}

private struct GuideCard: View {
    @Environment(\.onboardingEmphasis) private var emphasis
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            emphasis.solidSurface
                ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                : AnyShapeStyle(Color.primary.opacity(0.055)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(emphasis.strongEdge ? 0.45 : 0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
