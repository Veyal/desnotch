import SwiftUI

/// A short, privacy-safe introduction to the parts of desnotch that are easy to miss.
///
/// This view intentionally contains no live state or permission requests. It is safe to
/// present from the settings window and remains useful in previews and screenshots.
public struct OnboardingView: View {
    public var onOpenSettings: () -> Void
    public var onDone: () -> Void

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
                        symbol: "checklist",
                        tint: .purple,
                        title: "Turn on only what helps",
                        detail: "Reminders and the clipboard pocket are optional and off by default. Configure them in Settings when you need them."
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
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.black.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
                Text("Make the notch yours")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
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

private struct GuideCard: View {
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
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
