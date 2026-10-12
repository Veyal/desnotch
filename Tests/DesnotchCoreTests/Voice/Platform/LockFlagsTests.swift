import XCTest
@testable import DesnotchCore

final class LockFlagsTests: XCTestCase {
    func testLockFlagsUnlockedWhenNotLockedNotScreensaverAndOnConsole() {
        let flags = LockFlags(screenLocked: false, screensaverActive: false, onConsole: true)
        XCTAssertFalse(flags.isLocked)
    }

    func testLockFlagsLockedWhenScreenLocked() {
        let flags = LockFlags(screenLocked: true, screensaverActive: false, onConsole: true)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsLockedWhenScreensaverActive() {
        let flags = LockFlags(screenLocked: false, screensaverActive: true, onConsole: true)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsLockedWhenNotOnConsole() {
        let flags = LockFlags(screenLocked: false, screensaverActive: false, onConsole: false)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsLockedWhenScreenLockedAndScreensaverActive() {
        let flags = LockFlags(screenLocked: true, screensaverActive: true, onConsole: true)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsLockedWhenScreenLockedAndNotOnConsole() {
        let flags = LockFlags(screenLocked: true, screensaverActive: false, onConsole: false)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsLockedWhenScreensaverAndNotOnConsole() {
        let flags = LockFlags(screenLocked: false, screensaverActive: true, onConsole: false)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsLockedWhenAllTrueExceptOnConsole() {
        let flags = LockFlags(screenLocked: true, screensaverActive: true, onConsole: false)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsUnknownIsLocked() {
        XCTAssertTrue(LockFlags.unknown.isLocked)
        XCTAssertEqual(LockFlags.unknown, LockFlags(screenLocked: true, screensaverActive: false, onConsole: false))
    }

    func testLockFlagsFromNilDictionaryIsUnknown() {
        let flags = LockFlags.from(sessionDictionary: nil)
        XCTAssertEqual(flags, .unknown)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsFromUnlockedConsoleDictionary() {
        let dict: [String: Any] = ["kCGSSessionOnConsoleKey": true]
        let flags = LockFlags.from(sessionDictionary: dict)
        XCTAssertEqual(flags, LockFlags(screenLocked: false, screensaverActive: false, onConsole: true))
        XCTAssertFalse(flags.isLocked)
    }

    func testLockFlagsFromLockedConsoleDictionary() {
        let dict: [String: Any] = [
            "kCGSSessionOnConsoleKey": true,
            "CGSSessionScreenIsLocked": true
        ]
        let flags = LockFlags.from(sessionDictionary: dict)
        XCTAssertEqual(flags, LockFlags(screenLocked: true, screensaverActive: false, onConsole: true))
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsFromDictionaryMissingConsoleKeyIsLocked() {
        let dict: [String: Any] = [:]
        let flags = LockFlags.from(sessionDictionary: dict)
        XCTAssertFalse(flags.onConsole)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsFromDictionaryNotOnConsoleIsLocked() {
        let dict: [String: Any] = ["kCGSSessionOnConsoleKey": false]
        let flags = LockFlags.from(sessionDictionary: dict)
        XCTAssertFalse(flags.onConsole)
        XCTAssertTrue(flags.isLocked)
    }

    func testLockFlagsMergedLockNotificationWinsOverUnlockedDictionary() {
        let dictFlags = LockFlags(screenLocked: false, screensaverActive: false, onConsole: true)
        let merged = LockFlags.merged(dictionary: dictFlags, notificationLocked: true, screensaverActive: false)
        XCTAssertTrue(merged.screenLocked)
        XCTAssertTrue(merged.isLocked)
    }

    func testLockFlagsMergedUnlockNotificationDoesNotClearLockedDictionary() {
        let dictFlags = LockFlags(screenLocked: true, screensaverActive: false, onConsole: true)
        let merged = LockFlags.merged(dictionary: dictFlags, notificationLocked: false, screensaverActive: false)
        XCTAssertTrue(merged.screenLocked)
        XCTAssertTrue(merged.isLocked)
    }
}

@MainActor
final class ScreenLockMonitorTests: XCTestCase {
    func testMonitorWithoutObserversUnlockedConsoleIsFalse() {
        let monitor = ScreenLockMonitor(
            sessionDictionary: { ["kCGSSessionOnConsoleKey": true] },
            screensaverRunning: { false }
        )
        XCTAssertFalse(monitor.isLocked)
    }

    func testMonitorWithoutObserversNilDictionaryIsTrue() {
        let monitor = ScreenLockMonitor(
            sessionDictionary: { nil },
            screensaverRunning: { false }
        )
        XCTAssertTrue(monitor.isLocked)
    }

    func testMonitorWithoutObserversLockedDictionaryIsTrue() {
        let monitor = ScreenLockMonitor(
            sessionDictionary: { ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": true] },
            screensaverRunning: { false }
        )
        XCTAssertTrue(monitor.isLocked)
    }

    func testMonitorWithoutObserversScreensaverRunningIsTrue() {
        let monitor = ScreenLockMonitor(
            sessionDictionary: { ["kCGSSessionOnConsoleKey": true] },
            screensaverRunning: { true }
        )
        XCTAssertTrue(monitor.isLocked)
    }

    func testMonitorReReadsDictionaryOnEveryCall() {
        var currentDict: [String: Any]? = ["kCGSSessionOnConsoleKey": true]
        let monitor = ScreenLockMonitor(
            sessionDictionary: { currentDict },
            screensaverRunning: { false }
        )
        XCTAssertFalse(monitor.isLocked)

        currentDict = ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": true]
        XCTAssertTrue(monitor.isLocked)
    }

    func testMonitorCreatingAndDroppingStreamResetsFlags() {
        var currentDict: [String: Any]? = ["kCGSSessionOnConsoleKey": true]
        let monitor = ScreenLockMonitor(
            sessionDictionary: { currentDict },
            screensaverRunning: { false }
        )
        do {
            let stream = monitor.changes
            _ = stream
        }
        XCTAssertFalse(monitor.isLocked)
        currentDict = nil
        XCTAssertTrue(monitor.isLocked)
    }

    func testLockAndUnlockNotificationsReachTheStream() async {
        let center = NotificationCenter()
        let monitor = ScreenLockMonitor(
            sessionDictionary: { ["kCGSSessionOnConsoleKey": true] },
            screensaverRunning: { false },
            notificationCenter: center
        )
        let stream = monitor.changes
        var iterator = stream.makeAsyncIterator()
        center.post(name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        let locked = await iterator.next()
        XCTAssertEqual(locked, true)
        XCTAssertTrue(monitor.isLocked)
        center.post(name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        let unlocked = await iterator.next()
        XCTAssertEqual(unlocked, false)
        XCTAssertFalse(monitor.isLocked)
    }
}
