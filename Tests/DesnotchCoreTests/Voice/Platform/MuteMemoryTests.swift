import XCTest
@testable import DesnotchCore

final class MuteMemoryTests: XCTestCase {
    func testMuteAtPositiveLevelReturnsZeroAndRemembers() {
        var memory = MuteMemory()
        let target = memory.mute(current: 0.5)
        XCTAssertEqual(target, 0)
    }

    func testUnmuteAtZeroRestoresRememberedLevelThenForgets() {
        var memory = MuteMemory()
        _ = memory.mute(current: 0.5)
        let unmuted = memory.unmute(current: 0.0)
        XCTAssertEqual(unmuted, 0.5)

        // Second unmute has nothing remembered, falls back to 0.3
        let secondUnmute = memory.unmute(current: 0.0)
        XCTAssertEqual(secondUnmute, 0.3)
    }

    func testUnmuteWhenAlreadyAboveThresholdReturnsNilAndForgets() {
        var memory = MuteMemory()
        _ = memory.mute(current: 0.5)
        let unmuted = memory.unmute(current: 0.4)
        XCTAssertNil(unmuted)

        // Stale level is forgotten; next unmute at 0 returns default 0.3
        let nextUnmute = memory.unmute(current: 0.0)
        XCTAssertEqual(nextUnmute, 0.3)
    }

    func testMuteAtZeroReturnsNilAndRemembersNothing() {
        var memory = MuteMemory()
        let target = memory.mute(current: 0.0)
        XCTAssertNil(target)

        let unmuted = memory.unmute(current: 0.0)
        XCTAssertEqual(unmuted, 0.3)
    }

    func testMuteTwiceKeepsTheFirstRememberedLevel() {
        var memory = MuteMemory()
        _ = memory.mute(current: 0.5)
        _ = memory.mute(current: 0.2)
        let unmuted = memory.unmute(current: 0.0)
        XCTAssertEqual(unmuted, 0.5)
    }
}
