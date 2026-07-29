import Foundation

/// Publishes `AgentActivityScanner` results into SwiftUI state.
///
/// Unlike `NowPlayingController`, this polls: there is no OS notification for "a JSONL
/// transcript file changed", so a short repeating timer is the pragmatic option here. The scan
/// itself runs off the main actor since it does file I/O, and only the resulting lightweight
/// summary is published back.
@MainActor
final class AgentActivityController: ObservableObject {
    @Published private(set) var summary = AgentActivitySummary(sessions: [])

    private let scanInterval: TimeInterval = 5
    private var timer: Timer?

    init() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scan()
            }
        }
    }

    private func scan() {
        Task.detached(priority: .utility) {
            let sessions = AgentActivityScanner.scan(now: Date())
            let summary = AgentActivitySummary(sessions: sessions)
            await MainActor.run { [weak self] in
                self?.summary = summary
            }
        }
    }
}
