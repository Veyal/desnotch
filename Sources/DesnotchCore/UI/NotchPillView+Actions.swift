import SwiftUI

/// Click-to-jump actions (shared with the status-menu mirror).
extension NotchPillView {
    func activateMediaApp(_ info: NowPlayingInfo) {
        AppActivation.activateMediaApp(bundleIdentifier: info.bundleIdentifier)
    }

    func activateAgentHost(_ session: AgentSession) {
        AppActivation.activateAgentHost(projectPath: session.projectPath)
    }
}
