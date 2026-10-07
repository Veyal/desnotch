import SwiftUI

/// File tray section.
extension NotchPillView {
    /// Drop shelf: file references dragged onto the notch. Renders basenames + Finder
    /// icons only. Click opens the file; items can be dragged out; ✕ removes. At most
    /// `PillLimits.trayRows` rows show (the status menu lists the rest), so a long tray can
    /// never push the stack past the panel.
    var traySection: some View {
        let visible = Array(tray.items.prefix(rowCaps.tray))
        let hidden = PillLimits.hiddenCount(total: tray.items.count, shown: visible.count)
        return VStack(alignment: .leading, spacing: PillSpace.xs) {
            sectionHeader("Tray", icon: "tray.fill")

            if tray.items.isEmpty {
                trayDropWell
            } else {
                ForEach(visible, id: \.self) { url in
                    trayRow(url)
                        .transition(arrivalTransition)
                }
                if hidden > 0 {
                    overflowCaption("+\(hidden) more in the status menu")
                }
            }
        }
    }

    /// The empty tray's drop zone: a 40pt well, dashed at rest; while a file hovers it the
    /// dashes crossfade to a solid brighter outline, the fill lifts, the label swaps to
    /// "Drop to add" and the well grows a hair with the tactile spring. The shell itself
    /// stays black (the rim carries the shell-level highlight).
    private var trayDropWell: some View {
        let targeted = isDropTargeted
        let shape = RoundedRectangle(cornerRadius: PillRadius.row, style: .continuous)
        return HStack(spacing: PillSpace.s) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(targeted ? Color.white : captionColor)
                .accessibilityHidden(true)
            Text(targeted ? "Drop to add" : "Drop files here")
                .font(targeted ? PillTextStyle.bodyStrong.font : PillTextStyle.body.font)
                .foregroundStyle(targeted ? Color.white : secondaryColor)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            shape.fill(reduceTransparency
                ? PillPalette.opaqueWhite(targeted ? 0.12 : 0)
                : Color.white.opacity(targeted ? 0.08 : 0))
        )
        .overlay(
            shape
                .strokeBorder(
                    Color.white.opacity(0.25),
                    style: StrokeStyle(lineWidth: contrast == .increased ? 1.5 : 1, dash: [4, 3])
                )
                .opacity(targeted ? 0 : 1)
        )
        .overlay(
            shape
                .strokeBorder(Color.white.opacity(0.85), lineWidth: contrast == .increased ? 2 : 1.5)
                .opacity(targeted ? 1 : 0)
        )
        // Colour/label crossfade first (innermost), then the scale on its own spring.
        .animation(motion.swap, value: targeted)
        .scaleEffect(targeted && motion.allowsGeometry ? motion.dropWellScale : 1)
        .animation(targeted ? motion.contentIn : motion.release, value: targeted)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("File tray drop zone"))
        .accessibilityHint(Text("Drag files onto the notch to add them"))
    }

    private func trayRow(_ url: URL) -> some View {
        let name = privacyRedacted(url.lastPathComponent, fallback: trayPrivacyName(url))
        return HStack(spacing: PillRowLeading.gap) {
            trayIcon(url)
                .frame(width: 20, height: 20)
                .frame(width: PillRowLeading.slot)
                .accessibilityHidden(true)
                .animation(motion.swap, value: settings.privacyModeEnabled)
            Text(name)
                .font(PillTextStyle.title.font)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                // Row = leading slot, name, Spacer(min xs), 24pt button, three 8pt gaps: a cap that
                // forgets the gaps or the spacer overflows the row and shifts the whole
                // section left (the spotlight highlight then looks flush with the pill edge).
                .frame(
                    maxWidth: max(64, expandedContentWidth - PillRowLeading.slot - 24 - PillSpace.xs - PillSpace.s * 3),
                    alignment: .leading
                )
                .pillRedactionFade(settings.privacyModeEnabled, motion: motion)
                // The row's container label already speaks the name.
                .accessibilityHidden(true)
            Spacer(minLength: PillSpace.xs)
            Button {
                tray.remove(url)
            } label: {
                PillIconLabel(
                    systemName: "xmark.circle.fill", size: 12, weight: .regular, color: captionColor,
                    alignsTrailing: true
                )
            }
            .buttonStyle(PillButtonStyle())
            .accessibilityLabel(Text("Remove \(name) from tray"))
        }
        .frame(minHeight: PillRowHeight.listRow)
        .contentShape(Rectangle())
        .pillLandingFlash(
            landedTrayItem == url, motion: motion, reduceTransparency: reduceTransparency
        )
        .onTapGesture { _ = tray.open(url) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(privacyRedacted(
            url.lastPathComponent,
            fallback: trayPrivacyName(url)
        )))
        .accessibilityHint(Text("Opens file; more file actions are available"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open")) { _ = tray.open(url) }
        .accessibilityAction(named: Text("Reveal in Finder")) { _ = tray.revealInFinder(url) }
        .accessibilityAction(named: Text("Copy File")) { _ = tray.copyToPasteboard([url]) }
        .accessibilityAction(named: Text("Share")) { shareTrayItem(url) }
        .contextMenu {
            Button("Open") { _ = tray.open(url) }
            Button("Reveal in Finder") { _ = tray.revealInFinder(url) }
            Button("Copy File") { _ = tray.copyToPasteboard([url]) }
            Button("Share…") { shareTrayItem(url) }
            Divider()
            Button("Remove from Tray", role: .destructive) { tray.remove(url) }
        }
        // `NSItemProvider(contentsOf:)` registers a file representation, so dropping in
        // Finder performs a real copy (the plain NSURL provider only carried a URL type,
        // which Finder ignores).
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
        .help(privacyRedacted(url.lastPathComponent, fallback: trayPrivacyName(url)))
    }

    /// The file's Finder thumbnail, or a generic document glyph in Privacy mode: a QuickLook
    /// preview of a screenshot or document is the content itself, so it is never drawn while
    /// the pill may be screen-shared (the real image is not even built, not merely hidden).
    @ViewBuilder
    private func trayIcon(_ url: URL) -> some View {
        if settings.privacyModeEnabled {
            Image(systemName: "doc.fill")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(captionColor)
                .transition(.opacity)
        } else {
            Image(nsImage: tray.icon(for: url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .transition(.opacity)
        }
    }

    private func shareTrayItem(_ url: URL) {
        guard tray.items.contains(url),
              FileManager.default.fileExists(atPath: url.path),
              let panel = NSApp.windows.compactMap({ $0 as? NSPanel }).first(where: {
                  $0.styleMask.contains(.nonactivatingPanel)
              }),
              let anchor = panel.contentView
        else { return }
        let picker = NSSharingServicePicker(items: [url])
        // The panel is a mostly transparent, fixed-size host and its content view is flipped
        // (y grows downward, the pill hangs from y == 0), so `bounds.maxY` is the panel's
        // bottom, far from the pill. Anchor at the pointer when it is over the panel (the
        // context menu that triggers Share is on the row), else just under the cutout.
        let pointer = anchor.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        let origin = anchor.bounds.contains(pointer)
            ? pointer
            : CGPoint(x: anchor.bounds.midX, y: effectiveNotch.height)
        let rect = NSRect(x: origin.x, y: origin.y, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }
}
