import SwiftUI

/// Now-playing row. The section itself is `NowPlayingSectionView` (it needs the
/// accessibility environment, which an extension cannot hold); this just feeds it the
/// pill's state, with user content already behind `privacyRedacted`.
extension NotchPillView {
    func nowPlayingRow(_ info: NowPlayingInfo) -> some View {
        NowPlayingSectionView(
            info: info,
            title: privacyRedacted(info.title ?? "Unknown Title", fallback: "Now Playing"),
            artist: privacyRedacted(info.artist ?? "", fallback: ""),
            accessibilityText: privacyRedacted(
                "\(info.title ?? "Unknown Title")\(info.artist.map { ", \($0)" } ?? "")",
                fallback: "Now Playing"
            ),
            controller: controller,
            motion: motion,
            phase: expansionPhase,
            contentWidth: expandedContentWidth,
            privacy: settings.privacyModeEnabled,
            seekEnabled: settings.timelineSeekEnabled,
            equalizerOverArtwork: settings.musicIndicatorStyle == .equalizer,
            scrubPosition: $scrubPosition,
            onActivate: { activateMediaApp(info) }
        )
    }

    /// Accent for the minimized music indicator's equalizer: the artwork's color, or white
    /// with no artwork/grayscale art/privacy mode (the art's colors identify the track).
    var mediaAccent: Color {
        guard !settings.privacyModeEnabled, let accent = controller.info?.accent else { return .white }
        return Color(nsColor: accent)
    }
}
