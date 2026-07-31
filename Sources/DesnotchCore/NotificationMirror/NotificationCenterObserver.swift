import AppKit
import ApplicationServices
import os

/// Top-level (nonisolated) so the NSWorkspace observer closure can read it without
/// hopping onto the main actor.
private let notificationCenterBundleID = "com.apple.notificationcenterui"

/// Watches Notification Center's accessibility tree for newly created banner
/// windows and hands their readable text to `onBanner`.
///
/// This is the safest viable route to other apps' notifications: there is no public
/// API for observing them, the notifications SQLite DB is Full-Disk-Access-gated
/// (verified locally on macOS 15.5), and `usernoted`'s XPC surface is private and
/// entitlement-gated. AX observation needs exactly one user-granted, revocable
/// permission (Accessibility), sees banners only while they are on screen, and never
/// touches notification history at rest.
///
/// Resilience mirrors `MediaRemoteBridge`: if the NotificationCenter process is
/// missing or restarts (it relaunches on crash/logout), the observer re-attaches via
/// NSWorkspace launch tracking plus a slow retry timer. All AX calls run on the main
/// run loop - the observer's run-loop source is scheduled there.
@MainActor
final class NotificationCenterObserver {

    /// Raw joined text of a new banner (app name + title/body lines). Parsing and
    /// privacy policy live in the caller - this type only extracts strings. Return
    /// `true` to have the system banner closed (the caller decides: it knows whether
    /// the banner was actually mirrored and whether the user asked for dismissal).
    var onBanner: ((String) -> Bool)?

    private let logger = Logger(subsystem: "com.desnotch.app", category: "NotificationMirror")
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedPID: pid_t = 0
    private var retryTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?

    /// Whether the app currently holds the Accessibility permission.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's "grant Accessibility access" dialog (which has its own
    /// Open System Settings button) if the permission is missing.
    static func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        guard Self.isTrusted else { return }
        attach()
        // Re-attach if Notification Center relaunches (its banners live in a fresh
        // process with a new PID; the old AXObserver dies silently with it).
        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == notificationCenterBundleID else { return }
                Task { @MainActor in self?.attach() }
            }
        }
    }

    func stop() {
        detach()
        retryTimer?.invalidate()
        retryTimer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    // MARK: - Attachment

    private func attach() {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: notificationCenterBundleID
        ).first else {
            logger.notice("NotificationCenter process not found; retrying in 15s.")
            scheduleRetry()
            return
        }
        guard app.processIdentifier != observedPID || observer == nil else { return }
        detach()

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let self_ = Unmanaged<NotificationCenterObserver>.fromOpaque(refcon).takeUnretainedValue()
            // The run-loop source is scheduled on the main run loop, so this callback
            // is already on the main thread.
            MainActor.assumeIsolated {
                self_.handleNewWindow(element)
            }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success,
              let axObserver = created else {
            logger.error("AXObserverCreate failed; retrying in 15s.")
            scheduleRetry()
            return
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard AXObserverAddNotification(
            axObserver, appElement, kAXWindowCreatedNotification as CFString, refcon
        ) == .success else {
            logger.error("AXObserverAddNotification failed; retrying in 15s.")
            scheduleRetry()
            return
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode
        )
        observer = axObserver
        observedApp = appElement
        observedPID = app.processIdentifier
        retryTimer?.invalidate()
        retryTimer = nil
        logger.info("Attached to NotificationCenter (pid \(app.processIdentifier)).")
    }

    private func detach() {
        if let observer {
            if let observedApp {
                AXObserverRemoveNotification(observer, observedApp, kAXWindowCreatedNotification as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
            )
        }
        observer = nil
        observedApp = nil
        observedPID = 0
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: - Banner text extraction

    private func handleNewWindow(_ window: AXUIElement) {
        let lines = Self.collectText(from: window)
        guard !lines.isEmpty else { return } // Not a banner (or nothing readable).
        let shouldDismiss = onBanner?(lines.joined(separator: "\n")) ?? false
        guard shouldDismiss else { return }
        // Let the banner finish presenting before closing it: pressing the close
        // button mid-present is unreliable, and this window is only dismissed
        // because the caller confirmed it was mirrored into the pill.
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak self] in
            self?.dismiss(window)
        }
    }

    /// Grace before closing a mirrored banner - long enough for the present
    /// animation to settle, short enough that the banner barely registers.
    private let dismissDelay: TimeInterval = 0.35

    /// Closes a banner window by pressing its close/dismiss affordance.
    ///
    /// There is no supported way to stop a banner from appearing at all: notification
    /// delivery has no third-party hook, and Focus/DND (the only real suppression)
    /// would also stop the banner from ever being created - blinding this observer.
    /// So "don't show macOS notifications" is implemented as "close it right after we
    /// mirror it". The notification is NOT dismissed from Notification Center - only
    /// its on-screen banner - so nothing is lost.
    private func dismiss(_ window: AXUIElement) {
        // Preferred: the window's own close button.
        if let close = Self.copyAttribute(window, kAXCloseButtonAttribute as String),
           CFGetTypeID(close as CFTypeRef) == AXUIElementGetTypeID() {
            let element = close as! AXUIElement // Type-checked immediately above.
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                logger.debug("Dismissed mirrored banner via close button.")
                return
            }
        }
        // Fallback: a labelled Close/Clear/Dismiss button inside the banner tree.
        // Bounded walk, same caps as text collection.
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty && visited < 40 {
            let element = queue.removeFirst()
            visited += 1
            if let role = Self.copyAttribute(element, kAXRoleAttribute as String) as? String,
               role == kAXButtonRole as String {
                let label = [
                    Self.copyAttribute(element, kAXDescriptionAttribute as String) as? String,
                    Self.copyAttribute(element, kAXTitleAttribute as String) as? String
                ].compactMap { $0?.lowercased() }
                if label.contains(where: { ["close", "clear", "dismiss"].contains($0) }),
                   AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    logger.debug("Dismissed mirrored banner via labelled button.")
                    return
                }
            }
            if let children = Self.copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        logger.notice("Could not dismiss mirrored banner (no close affordance found).")
    }

    /// Breadth-first walk of a (banner) window collecting readable text. Sequoia's
    /// SwiftUI Notification Center exposes no static texts; the content lives in
    /// `AXAttributedDescription`/`AXDescription` on the banner's button element, so
    /// try those first on every node. Bounded (depth/node caps) - a banner tree is
    /// tiny, and the Notification Center *sidebar* window (also a "window created"
    /// event when opened) must not turn into an expensive full-tree walk.
    static func collectText(from root: AXUIElement, maxNodes: Int = 40) -> [String] {
        var lines: [String] = []
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty && visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            for attribute in ["AXAttributedDescription", kAXDescriptionAttribute as String, kAXTitleAttribute as String] {
                guard let value = copyAttribute(element, attribute) else { continue }
                let text: String
                if let attributed = value as? NSAttributedString {
                    text = attributed.string
                } else if let plain = value as? String {
                    text = plain
                } else {
                    continue
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !lines.contains(trimmed) {
                    lines.append(trimmed)
                }
            }
            if let children = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return lines
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
