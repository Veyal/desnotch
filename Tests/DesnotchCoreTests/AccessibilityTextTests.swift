import XCTest
@testable import DesnotchCore

final class AccessibilityTextTests: XCTestCase {
    func testVolumeAnnouncementRoundsAndClamps() {
        XCTAssertEqual(PillAnnouncements.volume(0.404), "Volume 40 percent")
        XCTAssertEqual(PillAnnouncements.volume(1.4), "Volume 100 percent")
        XCTAssertEqual(PillAnnouncements.volume(-1), "Volume 0 percent")
    }

    func testPowerAnnouncementNamesTheNewState() {
        XCTAssertEqual(PillAnnouncements.power(isPluggedIn: true, percent: 80), "Plugged in, 80 percent")
        XCTAssertEqual(PillAnnouncements.power(isPluggedIn: false, percent: 140), "On battery, 100 percent")
    }

    func testPinAnnouncement() {
        XCTAssertEqual(PillAnnouncements.pinned(true), "Notch held open")
        XCTAssertEqual(PillAnnouncements.pinned(false), "Notch released")
    }

    func testStatusMenuBatteryText() {
        XCTAssertEqual(
            StatusMenuText.battery(.init(percent: 64, isCharging: true)), "Battery 64% - charging"
        )
        XCTAssertEqual(
            StatusMenuText.battery(.init(percent: 12, isCharging: false)), "Battery 12% - on battery"
        )
    }

    func testFullOrPausedBatteryOnACReadsPluggedInNotOnBattery() {
        // kIOPSIsChargingKey is false on AC when full or held by Optimized Battery Charging.
        let held = BatteryController.BatteryState(percent: 100, isCharging: false, isPluggedIn: true)
        XCTAssertEqual(held.powerStatus, .pluggedIn)
        XCTAssertEqual(StatusMenuText.battery(held), "Battery 100% - plugged in")
        XCTAssertEqual(BatteryController.BatteryState(percent: 50, isCharging: true).powerStatus, .charging)
        XCTAssertTrue(BatteryController.BatteryState(percent: 50, isCharging: true).isPluggedIn)
        XCTAssertEqual(
            BatteryController.BatteryState(percent: 50, isCharging: false).powerStatus, .onBattery
        )
        // The toast keys on the power source, so a charge pause alone is not a plug event.
        let charging = BatteryController.BatteryState(percent: 79, isCharging: true)
        XCTAssertEqual(charging.isPluggedIn, held.isPluggedIn)
    }

    func testAgentRowLabelDoesNotRepeatTheProjectWhenTheTitleIsTheProject() {
        XCTAssertEqual(
            NotchPillView.agentRowLabel(
                source: "Claude Code", project: "desnotch", title: "desnotch",
                state: "working", reason: "in progress", freshness: "now"
            ),
            "Claude Code · desnotch · working · in progress · now"
        )
        XCTAssertEqual(
            NotchPillView.agentRowLabel(
                source: "Codex", project: "desnotch", title: "Fix the tray",
                state: "needs you", reason: "waiting", freshness: "2m"
            ),
            "Codex · desnotch · Fix the tray · needs you · waiting · 2m"
        )
    }

    func testStatusMenuHotProcessText() {
        let now = Date(timeIntervalSince1970: 10_000)
        let process = HotProcess(
            pid: 42, name: "node", cpu: 97.6, since: now.addingTimeInterval(-5 * 60 + 5)
        )
        XCTAssertEqual(StatusMenuText.hotProcess(process, now: now), "node - 97% CPU for 4 min")
    }

    func testStatusMenuDurationBuckets() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(StatusMenuText.duration(since: now.addingTimeInterval(-30), now: now), "under a minute")
        XCTAssertEqual(StatusMenuText.duration(since: now.addingTimeInterval(-3 * 3600 - 60), now: now), "3 h")
        XCTAssertEqual(StatusMenuText.duration(since: now.addingTimeInterval(60), now: now), "under a minute")
    }

    func testSeekStepMovesByTenSecondsAndClamps() {
        XCTAssertEqual(PlaybackSeekStep.target(from: 30, duration: 200, forward: true), 40)
        XCTAssertEqual(PlaybackSeekStep.target(from: 30, duration: 200, forward: false), 20)
        XCTAssertEqual(PlaybackSeekStep.target(from: 4, duration: 200, forward: false), 0)
        XCTAssertEqual(PlaybackSeekStep.target(from: 195, duration: 200, forward: true), 200)
        XCTAssertEqual(PlaybackSeekStep.target(from: 5, duration: -1, forward: true), 0)
    }
}
