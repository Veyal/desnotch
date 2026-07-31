import XCTest
@testable import DesnotchCore

final class MirroredNotificationParsingTests: XCTestCase {
    func testCommaJoinedBannerParses() {
        // Sequoia banner button description shape: "AppName, Title, Body".
        let n = MirroredNotification.parse(rawDescription: "Slack, John Doe, are we still on for 3pm?")
        XCTAssertEqual(n?.appName, "Slack")
        XCTAssertEqual(n?.content, "John Doe, are we still on for 3pm?")
    }

    func testNewlineSeparatedBannerParses() {
        let n = MirroredNotification.parse(rawDescription: "Messages\nAlex\nrunning late")
        XCTAssertEqual(n?.appName, "Messages")
        XCTAssertEqual(n?.content, "Alex, running late")
    }

    func testAppNameOnlyBannerHasNilContent() {
        let n = MirroredNotification.parse(rawDescription: "Finder")
        XCTAssertEqual(n?.appName, "Finder")
        XCTAssertNil(n?.content)
    }

    func testEmptyDescriptionRejected() {
        XCTAssertNil(MirroredNotification.parse(rawDescription: ""))
        XCTAssertNil(MirroredNotification.parse(rawDescription: "  \n\n  "))
    }

    func testContentTruncatedToCapWithEllipsis() {
        let long = String(repeating: "x", count: 100)
        let n = MirroredNotification.parse(rawDescription: "Mail\n\(long)")
        XCTAssertEqual(n?.content?.count, MirroredNotification.contentMax + 1) // cap + ellipsis
        XCTAssertTrue(n?.content?.hasSuffix("…") == true)
    }

    func testWhitespaceCollapsed() {
        let n = MirroredNotification.parse(rawDescription: "  Mail  \n  new   message   here ")
        XCTAssertEqual(n?.appName, "Mail")
        XCTAssertEqual(n?.content, "new message here")
    }

    func testSanitizeContentEmptyIsNil() {
        XCTAssertNil(MirroredNotification.sanitizeContent("   "))
        XCTAssertEqual(MirroredNotification.sanitizeContent("ok"), "ok")
    }
}

final class RunningAppPromotionTests: XCTestCase {
    private let running: Set<String> = ["telegram", "whatsapp", "google chrome", "safari"]

    func testAppNameFirstLayoutStillWins() {
        let n = MirroredNotification.parse(
            rawDescription: "Telegram, John, hi there", runningAppNames: running
        )
        XCTAssertEqual(n?.appName, "Telegram")
        XCTAssertEqual(n?.content, "John, hi there")
    }

    func testSenderFirstLayoutPromotesRunningApp() {
        let n = MirroredNotification.parse(
            rawDescription: "John Doe\nWhatsApp\nhi there", runningAppNames: running
        )
        XCTAssertEqual(n?.appName, "WhatsApp")
        XCTAssertEqual(n?.content, "John Doe, hi there") // original order, app chunk removed
    }

    func testBrowserDeliveryStaysAttributedToBrowser() {
        // WhatsApp Web via Chrome: both "Google Chrome" and "WhatsApp" are running;
        // first match in banner order wins, so the browser is never misclaimed as
        // the native app.
        let n = MirroredNotification.parse(
            rawDescription: "Google Chrome, WhatsApp, John: hi", runningAppNames: running
        )
        XCTAssertEqual(n?.appName, "Google Chrome")
        XCTAssertEqual(n?.content, "WhatsApp, John: hi")
    }

    func testMatchIsCaseInsensitive() {
        let n = MirroredNotification.parse(
            rawDescription: "John\nTELEGRAM\nping", runningAppNames: running
        )
        XCTAssertEqual(n?.appName, "TELEGRAM")
    }

    func testNoMatchFallsBackToFirstChunk() {
        // Sending app not running (e.g. APNs-delivered) -> Sequoia's app-name-first
        // assumption holds.
        let n = MirroredNotification.parse(
            rawDescription: "Mail, You have new mail", runningAppNames: running
        )
        XCTAssertEqual(n?.appName, "Mail")
        XCTAssertEqual(n?.content, "You have new mail")
    }

    func testEmptyRunningSetBehavesLikeBefore() {
        let n = MirroredNotification.parse(rawDescription: "Slack, John, hello")
        XCTAssertEqual(n?.appName, "Slack")
        XCTAssertEqual(n?.content, "John, hello")
    }

    func testNotificationCenterScaffoldingNeverBecomesTheApp() {
        // Regression (seen on hardware): the walk collects the host window's own
        // "Notification Center" title, and the promotion scan matched it because the
        // NotificationCenter *process* is a running app by that exact name.
        let runningWithNC = running.union(["notification center"])
        let n = MirroredNotification.parse(
            rawDescription: "Notification Center\nTelegram\nJohn\nhi",
            runningAppNames: runningWithNC
        )
        XCTAssertEqual(n?.appName, "Telegram")
        XCTAssertEqual(n?.content, "John, hi")
    }

    func testActionButtonChunksFilteredFromContent() {
        let n = MirroredNotification.parse(
            rawDescription: "Notification Center\nWhatsApp\nJohn\nhello\nClose\nOptions",
            runningAppNames: running
        )
        XCTAssertEqual(n?.appName, "WhatsApp")
        XCTAssertEqual(n?.content, "John, hello")
    }

    func testNoiseOnlyDescriptionRejected() {
        XCTAssertNil(MirroredNotification.parse(
            rawDescription: "Notification Center\nClose", runningAppNames: running
        ))
    }
}

@MainActor
final class NotificationMirrorSettingsTests: XCTestCase {
    private func freshStore(_ name: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }

    func testMirrorIsOffByDefault() {
        let store = freshStore("desnotch.tests.mirror-default")
        XCTAssertFalse(store.notificationMirrorEnabled)
    }

    func testMuteListPersistsAcrossStores() {
        let suite = "desnotch.tests.mirror-mute"
        let store = freshStore(suite)
        store.setNotificationApp("Slack", muted: true)
        XCTAssertTrue(store.mutedNotificationApps.contains("slack"))

        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(reloaded.mutedNotificationApps.contains("slack"))
    }

    func testBannerDismissalIsOffByDefaultAndPersists() {
        let suite = "desnotch.tests.mirror-dismiss"
        let store = freshStore(suite)
        XCTAssertFalse(store.dismissSystemBanners)
        store.dismissSystemBanners = true
        XCTAssertTrue(SettingsStore(defaults: UserDefaults(suiteName: suite)!).dismissSystemBanners)
    }

    func testMuteIsCaseInsensitiveAndDeduplicated() {
        let store = freshStore("desnotch.tests.mirror-case")
        store.setNotificationApp("Slack", muted: true)
        store.setNotificationApp("SLACK", muted: true)
        XCTAssertEqual(store.mutedNotificationApps, ["slack"])
        store.setNotificationApp("slack", muted: false)
        XCTAssertTrue(store.mutedNotificationApps.isEmpty)
    }

    func testControllerPermissionStateTransitions() {
        let store = freshStore("desnotch.tests.mirror-state")
        let controller = NotificationMirrorController(
            presentation: NotchPillPresentation(), settings: store
        )
        // Feature off by default -> .off regardless of AX trust.
        XCTAssertEqual(controller.permission, .off)
        // Enabling moves off .off; the concrete state depends on the test host's AX
        // trust (CI runners are untrusted -> .needsPermission), so assert the split.
        store.notificationMirrorEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)) // let the sink deliver
        XCTAssertNotEqual(controller.permission, .off)
        // Disabling always returns to .off and clears any banner.
        store.notificationMirrorEnabled = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.permission, .off)
        XCTAssertNil(controller.latest)
    }
}
