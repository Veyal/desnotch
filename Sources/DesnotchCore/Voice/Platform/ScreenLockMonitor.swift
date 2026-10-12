import AppKit
import Foundation

struct LockFlags: Equatable, Sendable {
    var screenLocked: Bool
    var screensaverActive: Bool
    var onConsole: Bool

    var isLocked: Bool {
        screenLocked || screensaverActive || !onConsole
    }

    static let unknown = LockFlags(screenLocked: true, screensaverActive: false, onConsole: false)

    static func from(sessionDictionary: [String: Any]?) -> LockFlags {
        guard let dict = sessionDictionary else {
            return .unknown
        }
        let onConsole = (dict["kCGSSessionOnConsoleKey"] as? Bool) == true
        let screenLocked = (dict["CGSSessionScreenIsLocked"] as? Bool) == true
        return LockFlags(screenLocked: screenLocked, screensaverActive: false, onConsole: onConsole)
    }

    static func merged(dictionary: LockFlags, notificationLocked: Bool, screensaverActive: Bool) -> LockFlags {
        LockFlags(
            screenLocked: dictionary.screenLocked || notificationLocked,
            screensaverActive: dictionary.screensaverActive || screensaverActive,
            onConsole: dictionary.onConsole
        )
    }
}

@MainActor
final class ScreenLockMonitor: LockStateProviding {
    private let sessionDictionary: @MainActor () -> [String: Any]?
    private let screensaverRunning: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter

    private var notificationLocked: Bool = false
    private var screensaverActive: Bool = false
    private var lastEmittedIsLocked: Bool?

    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var observerTokens: [NSObjectProtocol] = []

    init(
        sessionDictionary: @escaping @MainActor () -> [String: Any]? = {
            CGSessionCopyCurrentDictionary() as? [String: Any]
        },
        screensaverRunning: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" }
        },
        notificationCenter: NotificationCenter = DistributedNotificationCenter.default()
    ) {
        self.sessionDictionary = sessionDictionary
        self.screensaverRunning = screensaverRunning
        self.notificationCenter = notificationCenter
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    var isLocked: Bool {
        let dict = LockFlags.from(sessionDictionary: sessionDictionary())
        let activeScreensaver = screensaverActive || screensaverRunning()
        return LockFlags.merged(
            dictionary: dict,
            notificationLocked: notificationLocked,
            screensaverActive: activeScreensaver
        ).isLocked
    }

    var changes: AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeContinuation(id: id)
            }
        }

        let wasEmpty = continuations.isEmpty
        continuations[id] = continuation

        if wasEmpty {
            screensaverActive = screensaverRunning()
            installObservers()
            lastEmittedIsLocked = isLocked
        }

        return stream
    }

    private func installObservers() {
        guard observerTokens.isEmpty else { return }

        let lockName = NSNotification.Name("com.apple.screenIsLocked")
        let unlockName = NSNotification.Name("com.apple.screenIsUnlocked")
        let ssStart = NSNotification.Name("com.apple.screensaver.didstart")
        let ssStop = NSNotification.Name("com.apple.screensaver.didstop")

        let t1 = notificationCenter.addObserver(forName: lockName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.notificationLocked = true
                self.recomputeAndEmitIfChanged()
            }
        }

        let t2 = notificationCenter.addObserver(forName: unlockName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.notificationLocked = false
                self.recomputeAndEmitIfChanged()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.recomputeAndEmitIfChanged()
                    }
                }
            }
        }

        let t3 = notificationCenter.addObserver(forName: ssStart, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.screensaverActive = true
                self.recomputeAndEmitIfChanged()
            }
        }

        let t4 = notificationCenter.addObserver(forName: ssStop, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.screensaverActive = false
                self.recomputeAndEmitIfChanged()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.recomputeAndEmitIfChanged()
                    }
                }
            }
        }

        observerTokens = [t1, t2, t3, t4]
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            for token in observerTokens {
                notificationCenter.removeObserver(token)
            }
            observerTokens.removeAll()
            notificationLocked = false
            screensaverActive = false
            lastEmittedIsLocked = nil
        }
    }

    private func recomputeAndEmitIfChanged() {
        let current = isLocked
        if lastEmittedIsLocked != current {
            lastEmittedIsLocked = current
            for continuation in continuations.values {
                continuation.yield(current)
            }
        }
    }
}
