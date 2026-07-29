import SwiftUI

/// The live-activity pill itself.
///
/// Three states, not two: hidden (nothing playing), collapsed (media active, a
/// small hoverable indicator sits at the notch), and expanded (the full pill with
/// artwork/text/controls). It expands briefly on a real change and auto-collapses -
/// like a toast, not a persistent panel - and hovering the collapsed indicator
/// re-expands it manually. All transitions are spring-driven (`.animation` tied to
/// `NowPlayingController`'s published state), not manual frame timers.
///
/// Alongside now-playing, a second content mode renders coarse AI agent activity.
/// Priority: now-playing wins whenever it's visible, since it has real playback
/// controls the user directly acts on; agent activity only takes the pill when
/// now-playing has nothing to show.
struct NotchPillView: View {
    @ObservedObject var controller: NowPlayingController
    @ObservedObject var agentActivity: AgentActivityController
    let hasPhysicalNotch: Bool

    private let spring = Animation.spring(response: 0.45, dampingFraction: 0.75)

    var body: some View {
        Group {
            if controller.hasActiveMedia, let info = controller.info {
                if controller.isExpanded {
                    expandedContent(for: info)
                        .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                } else {
                    collapsedContent(for: info)
                        .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                }
            } else if agentActivity.summary.hasActivity {
                agentActivityContent(for: agentActivity.summary)
                    .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
            } else {
                Color.clear
                    .frame(width: NotchGeometry.fallbackWidth, height: NotchGeometry.fallbackHeight)
            }
        }
        .animation(spring, value: controller.isExpanded)
        .animation(spring, value: controller.hasActiveMedia)
        .animation(spring, value: agentActivity.summary.hasActivity)
        .onHover { hovering in
            controller.setHovering(hovering)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func collapsedContent(for info: NowPlayingInfo) -> some View {
        artwork(info.artwork, size: 16)
            .padding(7)
            .background(Capsule().fill(.black.opacity(0.85)))
            .padding(.top, hasPhysicalNotch ? 2 : 6)
    }

    private func agentActivityContent(for summary: AgentActivitySummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: summary.needsYourTurnCount > 0 ? "bolt.fill" : "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(summary.needsYourTurnCount > 0 ? .yellow : .white)

            Text(summary.headline)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.black.opacity(0.85))
        )
        .padding(.top, hasPhysicalNotch ? 2 : 6)
    }

    private func expandedContent(for info: NowPlayingInfo) -> some View {
        HStack(spacing: 10) {
            artwork(info.artwork, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(info.title ?? "Unknown Title")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(info.artist ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 160, alignment: .leading)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                controlButton(systemName: "backward.fill") { controller.previous() }
                controlButton(systemName: info.isPlaying ? "pause.fill" : "play.fill") {
                    controller.togglePlayPause()
                }
                controlButton(systemName: "forward.fill") { controller.next() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.black.opacity(0.85))
        )
        .padding(.top, hasPhysicalNotch ? 2 : 6)
    }

    private func artwork(_ image: NSImage?, size: CGFloat) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size >= 24 ? 5 : 4))
    }

    private func controlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: 20)
    }
}
