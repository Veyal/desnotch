import Foundation

/// Why the pill was flashed open. The kind picks the hold time, which section is
/// spotlighted (it reveals first and gets a brief highlight), and the rim glow tint. It is
/// visual only: VoiceOver announcements are passed separately and are unchanged.
public enum PillFlashKind: Equatable, CaseIterable {
    case tray, power, reminder, timerStarted, timerComplete, notification, voice

    /// How long the pill is held open (seconds).
    public var holdDuration: TimeInterval {
        switch self {
        case .tray, .reminder: return 1.6
        case .power: return 2.4
        case .timerStarted: return 2.0
        case .timerComplete, .notification: return 4.0
        case .voice: return 3.0
        }
    }

    /// The section this flash is about.
    var spotlight: PillSectionKind {
        switch self {
        case .tray: return .tray
        case .power: return .battery
        case .reminder: return .reminders
        case .timerStarted, .timerComplete: return .timer
        case .notification: return .notification
        case .voice: return .voice
        }
    }

    enum RimHue: Equatable { case neutral, green, amber, cyan }

    /// Rim glow color. `pluggedIn` only matters for `.power` (green plugged in, amber on
    /// battery).
    func rim(pluggedIn: Bool = true) -> (hue: RimHue, opacity: Double) {
        switch self {
        case .tray: return (.neutral, 0.35)
        case .power: return (pluggedIn ? .green : .amber, 0.5)
        case .reminder: return (.green, 0.5)
        case .timerStarted: return (.cyan, 0.5)
        case .timerComplete: return (.green, 0.6)
        case .notification: return (.neutral, 0.30)
        case .voice: return (.cyan, 0.5)
        }
    }
}

/// Tracks the pill's hover state, shared by both content modes.
///
/// The pill minimizes by default and expands only while the pointer is over it (`isHovering`);
/// a short exit grace avoids flicker on edge crossings. Timers run on `.common` run-loop mode
/// so they keep firing during menu tracking.
@MainActor
public final class NotchPillPresentation: ObservableObject {
    @Published public private(set) var isHovering = false

    /// Momentary volume readout (0...1) after a scroll-to-adjust gesture; auto-clears.
    @Published public private(set) var volumeFlash: Float?

    /// Brief forced-open state so the user sees a change land (a file dropped into the
    /// tray, the power cable plugged/unplugged) even without hovering; auto-clears.
    @Published public private(set) var openFlash = false

    /// What the current `openFlash` is for (nil for an unclassified flash); cleared with it.
    @Published public private(set) var flashKind: PillFlashKind?

    /// Monotonic one-shot event for visual acknowledgement. Unlike `openFlash`, this
    /// changes even when another event arrives while the pill is already being held open.
    @Published public private(set) var feedbackToken = 0

    /// Grace period after the mouse leaves before clearing hover, so briefly crossing the
    /// edge doesn't collapse an expanded pill. User-configurable (Settings > Collapse delay);
    /// read at scheduling time so changes apply to the next exit immediately.
    private var hoverExitDelay: TimeInterval { SettingsStore.shared.hoverCollapseDelay }
    private var exitTimer: Timer?
    private var volumeFlashTimer: Timer?
    private var openFlashTimer: Timer?
    /// `systemUptime` at which the current hold ends (0 when no flash is held).
    private var openFlashDeadline: TimeInterval = 0

    public init() {}

    /// Called by the window controller's cursor tracker on every relevant mouse event -
    /// the single authority for hover (the SwiftUI `.onHover` path was removed: its exit
    /// events raced panel resizes and could strand the pill closed under a stationary
    /// cursor, or open with the cursor long gone). Publishes only on real changes so the
    /// event-rate calls stay cheap.
    public func setHovering(_ hovering: Bool) {
        if hovering {
            exitTimer?.invalidate()
            exitTimer = nil
            if !isHovering {
                isHovering = true
            }
        } else {
            guard isHovering, exitTimer == nil else { return }
            // The callback runs synchronously on the main run loop (never a deferred `Task`):
            // a hop would let a stale expiry land after a newer hover and collapse it.
            let timer = Timer(timeInterval: hoverExitDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in
                    self?.exitTimer = nil
                    self?.isHovering = false
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            exitTimer = timer
        }
    }

    /// Show the volume level briefly after a scroll adjustment.
    public func flashVolume(_ level: Float) {
        volumeFlash = level
        volumeFlashTimer?.invalidate()
        // Announce once the scroll burst settles (the timer restarts on every step), so VoiceOver
        // reads the final level instead of queueing an announcement per scroll tick.
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                if let level = self.volumeFlash {
                    AccessibilityAnnouncer.announce(PillAnnouncements.volume(level))
                }
                self.volumeFlash = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeFlashTimer = timer
    }

    /// Hold the pill open briefly so a state change is visible without hovering. The optional
    /// `announcement` is the VoiceOver equivalent of the visual flash.
    /// `duration` defaults to the kind's hold time (1.5s without a kind). A flash while
    /// the pill is already held open only ever extends the hold (a shorter flash can never
    /// cut a longer one short) and replays the feedback; the spotlight/rim kind follows the
    /// flash that owns the longer hold.
    public func flashOpen(
        for duration: TimeInterval? = nil,
        announcement: String? = nil,
        kind: PillFlashKind? = nil
    ) {
        if let announcement {
            AccessibilityAnnouncer.announce(announcement)
        }
        let duration = duration ?? kind?.holdDuration ?? 1.5
        let now = ProcessInfo.processInfo.systemUptime
        let hold = Self.mergedHold(
            currentDeadline: openFlash ? openFlashDeadline : nil, now: now, duration: duration
        )
        openFlashDeadline = hold.deadline
        if hold.extends { flashKind = kind }
        feedbackToken &+= 1
        openFlash = true
        openFlashTimer?.invalidate()
        let timer = Timer(timeInterval: max(0, hold.deadline - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.openFlash = false
                self?.flashKind = nil
                self?.openFlashDeadline = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        openFlashTimer = timer
    }

    /// The hold a flash of `duration` starting at `now` produces while another may be running:
    /// the later of the two deadlines, and whether the new flash is the one that owns it
    /// (ties go to the newer flash).
    nonisolated static func mergedHold(
        currentDeadline: TimeInterval?, now: TimeInterval, duration: TimeInterval
    ) -> (deadline: TimeInterval, extends: Bool) {
        let proposed = now + max(0, duration)
        guard let currentDeadline, currentDeadline > now else { return (proposed, true) }
        return proposed >= currentDeadline ? (proposed, true) : (currentDeadline, false)
    }

    /// Forget hover state (used when all activity clears).
    public func reset() {
        exitTimer?.invalidate()
        volumeFlashTimer?.invalidate()
        openFlashTimer?.invalidate()
        exitTimer = nil
        volumeFlashTimer = nil
        openFlashTimer = nil
        isHovering = false
        volumeFlash = nil
        openFlash = false
        openFlashDeadline = 0
        flashKind = nil
    }
}
