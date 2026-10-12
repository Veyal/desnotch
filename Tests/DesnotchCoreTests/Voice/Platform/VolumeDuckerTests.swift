import XCTest
@testable import DesnotchCore

@MainActor
final class VolumeDuckerTests: XCTestCase {
    func testDuckAndRestoreNormal() {
        let fake = FakeVolumeControl(level: 0.6)
        let ducker = VolumeDucker(volume: fake)

        ducker.duck()
        XCTAssertEqual(fake.level ?? 0, 0.15, accuracy: 0.0001)

        ducker.restore()
        XCTAssertEqual(fake.level ?? 0, 0.6, accuracy: 0.0001)
    }

    func testUserChangedVolumeMeanwhileLeavesUserVolume() {
        let fake = FakeVolumeControl(level: 0.6)
        let ducker = VolumeDucker(volume: fake)

        ducker.duck()
        XCTAssertEqual(fake.level ?? 0, 0.15, accuracy: 0.0001)

        fake.level = 0.4
        ducker.restore()
        XCTAssertEqual(fake.level ?? 0, 0.4, accuracy: 0.0001)
    }

    func testDuckAtOrBelowThresholdIsNoOp() {
        let fake = FakeVolumeControl(level: 0.1)
        let ducker = VolumeDucker(volume: fake)

        ducker.duck()
        XCTAssertEqual(fake.deltas.count, 0)
        XCTAssertEqual(fake.level ?? 0, 0.1, accuracy: 0.0001)

        ducker.restore()
        XCTAssertEqual(fake.deltas.count, 0)
        XCTAssertEqual(fake.level ?? 0, 0.1, accuracy: 0.0001)
    }

    func testDoubleDuckKeepsFirstOriginal() {
        let fake = FakeVolumeControl(level: 0.6)
        let ducker = VolumeDucker(volume: fake)

        ducker.duck()
        XCTAssertEqual(fake.level ?? 0, 0.15, accuracy: 0.0001)

        ducker.duck()
        XCTAssertEqual(fake.level ?? 0, 0.15, accuracy: 0.0001)

        ducker.restore()
        XCTAssertEqual(fake.level ?? 0, 0.6, accuracy: 0.0001)
    }

    func testUnsettableDeviceNoState() {
        let fake = FakeVolumeControl(level: nil, adjustable: false)
        let ducker = VolumeDucker(volume: fake)

        ducker.duck()
        XCTAssertEqual(fake.deltas.count, 0)

        ducker.restore()
        XCTAssertEqual(fake.deltas.count, 0)
    }
}
