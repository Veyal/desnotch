import SwiftUI

/// Clipboard history section.
extension NotchPillView {
    var clipboardSection: some View {
        let entries = Array(clipboard.entries.prefix(rowCaps.clipboard))
        let hidden = PillLimits.hiddenCount(total: clipboard.entries.count, shown: entries.count)
        return VStack(alignment: .leading, spacing: PillSpace.xs) {
            sectionHeader("Clipboard", icon: "doc.on.clipboard") {
                Button {
                    clipboard.clear()
                } label: {
                    PillIconLabel(
                        systemName: "trash", size: 11, weight: .semibold, color: captionColor,
                        alignsTrailing: true
                    )
                }
                .buttonStyle(PillButtonStyle())
                .help("Clear clipboard history")
                .accessibilityLabel(Text("Clear clipboard history"))
            }

            ForEach(entries) { entry in
                clipboardRow(entry)
                    .id(entry.id)
                    .transition(arrivalTransition)
            }

            if hidden > 0 {
                overflowCaption("+\(hidden) more in the status menu")
            }
        }
    }

    private func clipboardRow(_ entry: ClipboardEntry) -> some View {
        let copied = clipboard.copiedEntryID == entry.id
        return HStack(spacing: PillSpace.xs) {
            Button {
                clipboard.copy(entry.id)
                PillHaptics.play(.clipboardCopy)
            } label: {
                HStack(spacing: PillRowLeading.gap) {
                    // Copy -> check: the symbol replaces itself (macOS 14) or crossfades.
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? PillPalette.green.color : captionColor)
                        .frame(width: PillRowLeading.slot)
                        .availabilityGuardedSymbolReplace(enabled: motion.allowsPulse)
                        .animation(motion.swap, value: copied)
                        .accessibilityHidden(true)
                    Text(privacyRedacted(entry.preview, fallback: "Clipboard text hidden"))
                        .font(PillTextStyle.body.font)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: max(64, expandedContentWidth - PillRowLeading.titleInset - 24 - PillSpace.xs), alignment: .leading)
                        .pillRedactionFade(settings.privacyModeEnabled, motion: motion)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: PillRowHeight.listRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(PillButtonStyle(role: .row))
            .help("Copy this item")
            .accessibilityLabel(Text("Copy \(privacyRedacted(entry.preview, fallback: "clipboard item"))"))

            Button {
                clipboard.remove(entry.id)
            } label: {
                PillIconLabel(
                    systemName: "xmark.circle.fill", size: 12, weight: .regular, color: captionColor,
                    alignsTrailing: true
                )
            }
            .buttonStyle(PillButtonStyle())
            .help("Remove from clipboard history")
            .accessibilityLabel(Text("Remove clipboard item"))
        }
        // A new entry glows briefly (white); a copy washes the row green and fades it out.
        .pillLandingFlash(
            landedClipboardID == entry.id, motion: motion, reduceTransparency: reduceTransparency
        )
        .pillLandingFlash(
            copied, motion: motion, tint: PillPalette.green, peak: 0.16,
            reduceTransparency: reduceTransparency
        )
    }
}
