import SwiftUI

/// Mirrored notification banner row.
extension NotchPillView {
    /// The mirrored banner row - always the top section (it's the newest event).
    /// The row's identity is constant: a new banner while one is showing swaps only the
    /// leaves (icon tile scales/crossfades, texts blur-slide, keyed on `arrivalCount`), so
    /// the row never re-lays out. Fixed vertical metrics (two fixed-height lines, capped
    /// widths) mean arrival and expiry never change the measured height mid-animation; only
    /// the section's first appearance and expiry change stack geometry.
    func notificationRow(_ banner: MirroredNotification) -> some View {
        let arrival = notificationMirror.arrivalCount
        let textWidth = max(64, expandedContentWidth - 32 - 30 - PillSpace.s - PillSpace.s - PillSpace.xs)
        return Button {
            notificationMirror.activateSource(appName: banner.appName)
        } label: {
            HStack(spacing: PillSpace.s) {
                // The icon is the alert's anchor: app-sized, rounded like a system badge,
                // bell fallback in a matching tile so both variants share one silhouette.
                ZStack {
                    notificationIcon(banner)
                        .id(arrival)
                        .transition(iconTransition)
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: PillRadius.control, style: .continuous))
                .animation(motion.swap, value: arrival)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    ZStack(alignment: .leading) {
                        Text(banner.appName)
                            .font(PillTextStyle.title.font)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .id(arrival)
                            .transition(.pillBlurSlide(motion, blurAllowed: blurAllowed))
                    }
                    .frame(height: 16, alignment: .leading)
                    .clipped()

                    ZStack(alignment: .leading) {
                        Text(privacyRedacted(banner.content ?? "Notification", fallback: "Notification"))
                            .font(PillTextStyle.body.font)
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                            .id(arrival)
                            .transition(.pillBlurSlide(motion, blurAllowed: blurAllowed, secondLine: true))
                            .pillRedactionFade(settings.privacyModeEnabled, motion: motion)
                    }
                    .frame(height: 14, alignment: .leading)
                    .clipped()
                }
                .frame(maxWidth: textWidth, alignment: .leading)
                .animation(motion.swap, value: arrival)

                Spacer(minLength: PillSpace.xs)

                // Seconds-resolution age of a banner that lives at most a minute.
                PillClock(cadence: .second) { now in
                    Text(relativeTime(banner.receivedAt, now: now))
                        .font(PillTextStyle.caption.font.monospacedDigit())
                        .foregroundStyle(captionColor)
                        .frame(width: 30, alignment: .trailing)
                        .transaction { $0.animation = nil }
                }
            }
            .frame(minHeight: PillRowHeight.tall)
            .contentShape(Rectangle())
        }
        .buttonStyle(PillButtonStyle(role: .row))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Notification from \(banner.appName)\(settings.privacyModeEnabled ? "" : (banner.content.map { ": \($0)" } ?? ""))"))
        .accessibilityHint(Text("Opens \(banner.appName)"))
        .transition(arrivalTransition)
    }

    @ViewBuilder
    private func notificationIcon(_ banner: MirroredNotification) -> some View {
        if let icon = notificationMirror.sourceIcon(for: banner.appName) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
        } else {
            ZStack {
                PillPalette.surfaceControl
                Image(systemName: "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
        }
    }

    /// The incoming icon scales up from 0.9 while fading (replacement only; the leaving one
    /// just fades). Pure fade without geometry.
    private var iconTransition: AnyTransition {
        motion.allowsGeometry
            ? .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.9)),
                removal: .opacity
            )
            : .opacity
    }
}
