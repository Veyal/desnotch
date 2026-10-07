import SwiftUI

/// Stuck-process section.
extension NotchPillView {
    /// Presumed-stuck processes (sustained high CPU). Rows show name, current CPU%, and
    /// how long the streak has lasted - enough to decide whether to go kill something. At
    /// most `PillLimits.processRows` rows show. Rows come and go with the arrival
    /// transition; the CPU figure itself updates on each sample without animating.
    var processSection: some View {
        let rows = Array(processMonitor.hotProcesses.prefix(rowCaps.processes))
        let hidden = PillLimits.hiddenCount(total: processMonitor.hotProcesses.count, shown: rows.count)
        return VStack(alignment: .leading, spacing: PillSpace.xs) {
            sectionHeader("High CPU", icon: "flame.fill", iconTint: PillPalette.orange.color)

            ForEach(rows) { proc in
                HStack(spacing: PillRowLeading.gap) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(captionColor)
                        .frame(width: PillRowLeading.slot)
                        .accessibilityHidden(true)
                    Text(proc.name)
                        .font(PillTextStyle.title.font)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(
                            maxWidth: max(64, expandedContentWidth - PillRowLeading.titleInset - 52 - 36 - PillSpace.xs - PillSpace.s * 2),
                            alignment: .leading
                        )
                    Spacer(minLength: PillSpace.xs)
                    PillChip(
                        text: "\(Int(proc.cpu))%",
                        tint: PillPalette.orange,
                        reduceTransparency: reduceTransparency
                    )
                    .transaction { $0.animation = nil }
                    PillClock { now in
                        Text(relativeTime(proc.since, now: now))
                            .font(PillTextStyle.caption.font.monospacedDigit())
                            .foregroundStyle(captionColor)
                            .frame(width: 36, alignment: .trailing)
                            .transaction { $0.animation = nil }
                    }
                }
                .frame(minHeight: PillRowHeight.listRow)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(proc.name) at \(Int(proc.cpu)) percent CPU"))
                .transition(arrivalTransition)
            }

            if hidden > 0 {
                overflowCaption("+\(hidden) more")
            }
        }
    }
}
