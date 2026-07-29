import SwiftUI

/// The live-activity pill itself.
///
/// Open/close is driven entirely by SwiftUI's animation system (`.spring()` tied to
/// `isVisible`), not manual frame timers - the spec calls for a smooth, jank-free
/// reveal, and hand-rolled per-frame animation is exactly what SwiftUI's implicit/
/// explicit animations exist to avoid.
struct NotchPillView: View {
    @ObservedObject var controller: NowPlayingController
    @ObservedObject var agentActivity: AgentActivityController
    let hasPhysicalNotch: Bool

    /// Which of the two content modes is on screen right now, if any.
    ///
    /// Priority: now-playing wins whenever it's visible. It's the mode with actual playback
    /// controls the user directly acts on, so it shouldn't get bumped by ambient agent-status
    /// text; agent activity only takes the pill when there's no now-playing content to show.
    /// When agent activity was already showing and now-playing starts, the swap still animates
    /// because this is keyed as its own `Equatable` value below, not just an isVisible bool.
    private enum ContentKind: Equatable {
        case nowPlaying
        case agentActivity
        case none
    }

    private var contentKind: ContentKind {
        if controller.isVisible, controller.info != nil {
            return .nowPlaying
        } else if agentActivity.summary.hasActivity {
            return .agentActivity
        } else {
            return .none
        }
    }

    var body: some View {
        Group {
            switch contentKind {
            case .nowPlaying:
                if let info = controller.info {
                    content(for: info)
                        .transition(
                            .scale(scale: 0.6, anchor: .top)
                                .combined(with: .opacity)
                        )
                }
            case .agentActivity:
                agentActivityContent(for: agentActivity.summary)
                    .transition(
                        .scale(scale: 0.6, anchor: .top)
                            .combined(with: .opacity)
                    )
            case .none:
                Color.clear
                    .frame(width: NotchGeometry.fallbackWidth, height: NotchGeometry.fallbackHeight)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: contentKind)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private func content(for info: NowPlayingInfo) -> some View {
        HStack(spacing: 10) {
            artwork(info.artwork)

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

    private func artwork(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 5))
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
