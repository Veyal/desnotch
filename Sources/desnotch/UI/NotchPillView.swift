import SwiftUI

/// The live-activity pill itself.
///
/// Open/close is driven entirely by SwiftUI's animation system (`.spring()` tied to
/// `isVisible`), not manual frame timers - the spec calls for a smooth, jank-free
/// reveal, and hand-rolled per-frame animation is exactly what SwiftUI's implicit/
/// explicit animations exist to avoid.
struct NotchPillView: View {
    @ObservedObject var controller: NowPlayingController
    let hasPhysicalNotch: Bool

    var body: some View {
        Group {
            if controller.isVisible, let info = controller.info {
                content(for: info)
                    .transition(
                        .scale(scale: 0.6, anchor: .top)
                            .combined(with: .opacity)
                    )
            } else {
                Color.clear
                    .frame(width: NotchGeometry.fallbackWidth, height: NotchGeometry.fallbackHeight)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: controller.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
