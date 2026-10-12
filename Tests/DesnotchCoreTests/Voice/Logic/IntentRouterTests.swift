import XCTest
@testable import DesnotchCore

/// ctx: 0 = A (lane unavailable, not busy), 1 = B (lane available), 2 = C (agent busy).
private let routerCases: [(n: Int, utterance: String, ctx: Int, expected: RouteDecision)] = [
    (1, "Play", 0, .local(.mediaPlay)),
    (2, "  PAUSE music, please. ", 0, .local(.mediaPause)),
    (3, "stop", 0, .local(.mediaPause)),
    (4, "stop", 2, .cancelTurn),
    (5, "cancel", 0, .reject(.ambiguous)),
    (6, "cancel", 2, .cancelTurn),
    (7, "cancel the timer", 0, .local(.timerCancel)),
    (8, "abort agent", 0, .emergencyStop),
    (9, "Abort the agent!", 2, .emergencyStop),
    (10, "next song", 0, .local(.mediaNext)),
    (11, "skip", 0, .local(.mediaNext)),
    (12, "previous track", 0, .local(.mediaPrevious)),
    (13, "volume 30", 0, .local(.volumeSet(percent: 30))),
    (14, "set the volume to thirty percent", 0, .local(.volumeSet(percent: 30))),
    (15, "volume to twenty five", 0, .local(.volumeSet(percent: 25))),
    (16, "volume twenty-five", 0, .local(.volumeSet(percent: 25))),
    (17, "volume to 100", 0, .local(.volumeSet(percent: 100))),
    (18, "volume zero", 0, .local(.volumeSet(percent: 0))),
    (19, "volume 150", 0, .reject(.invalidArgument)),
    (20, "volume", 0, .reject(.ambiguous)),
    (21, "volume to", 0, .reject(.invalidArgument)),
    (22, "set volume to banana", 0, .reject(.invalidArgument)),
    (23, "louder", 0, .local(.volumeStep(delta: 10))),
    (24, "turn it down a bit", 0, .local(.volumeStep(delta: -5))),
    (25, "volume up a little", 0, .local(.volumeStep(delta: 5))),
    (26, "quieter", 0, .local(.volumeStep(delta: -10))),
    (27, "mute", 0, .local(.mute)),
    (28, "un-mute", 0, .local(.unmute)),
    (29, "open Safari", 0, .local(.openApp(bundleID: "com.apple.Safari", name: "Safari"))),
    (30, "please open the activity monitor app", 0,
     .local(.openApp(bundleID: "com.apple.ActivityMonitor", name: "Activity Monitor"))),
    (31, "launch VS Code", 0,
     .local(.openApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"))),
    (32, "open sofari", 0, .reject(.unknownApp)),
    (33, "open", 0, .reject(.ambiguous)),
    (34, "open the pod bay doors", 1, .reject(.unknownApp)),
    (35, "open my latest nmap scan results in a text editor", 1,
     .remote(utterance: "open my latest nmap scan results in a text editor")),
    (36, "timer 10 minutes", 0, .local(.timerStart(minutes: 10))),
    (37, "set a timer for five minutes", 0, .local(.timerStart(minutes: 5))),
    (38, "set a 25 minute timer", 0, .local(.timerStart(minutes: 25))),
    (39, "timer 0 minutes", 0, .reject(.invalidArgument)),
    (40, "timer 500 minutes", 0, .reject(.invalidArgument)),
    (41, "timer", 0, .reject(.ambiguous)),
    (42, "timer ten", 0, .reject(.invalidArgument)),
    (43, "putar musik", 0, .local(.mediaPlay)),
    (44, "jeda", 0, .local(.mediaPause)),
    (45, "lagu berikutnya", 0, .local(.mediaNext)),
    (46, "volume ke lima puluh persen", 0, .local(.volumeSet(percent: 50))),
    (47, "atur volume jadi tujuh puluh", 0, .local(.volumeSet(percent: 70))),
    (48, "kecilkan volume sedikit", 0, .local(.volumeStep(delta: -5))),
    (49, "buka aplikasi kalender", 0,
     .local(.openApp(bundleID: "com.apple.iCal", name: "Calendar"))),
    (50, "setel timer lima belas menit", 0, .local(.timerStart(minutes: 15))),
    (51, "batalkan timer", 0, .local(.timerCancel)),
    (52, "batalkan agent", 0, .emergencyStop),
    (53, "What's the weather in Jakarta?", 0, .reject(.notLocalCommand)),
    (54, "What's the weather in Jakarta?", 1,
     .remote(utterance: "What's the weather in Jakarta?")),
    (55, "", 0, .reject(.emptyUtterance)),
    (56, "   ", 0, .reject(.emptyUtterance)),
    (57, "um", 0, .reject(.emptyUtterance)),
    (58, String(repeating: "x", count: 501), 0, .reject(.tooLong)),
    (59, "play something by Radiohead", 0, .reject(.notLocalCommand)),
    (60, "play something by Radiohead", 1, .remote(utterance: "play something by Radiohead")),
    (61, "pause the scan", 1, .remote(utterance: "pause the scan")),
    (62, "stop the scan", 2, .reject(.notLocalCommand)),
    (63, "hey desnotch volume 20", 0, .local(.volumeSet(percent: 20))),
    (64, "tolong buka safari dong", 0,
     .local(.openApp(bundleID: "com.apple.Safari", name: "Safari"))),
    (65, "pause a bit", 0, .reject(.notLocalCommand)),
    (66, "mute the TV", 0, .reject(.notLocalCommand)),
    (67, "volume up", 2, .local(.volumeStep(delta: 10))),
    (68, "hentikan", 2, .cancelTurn),
    (69, "hentikan", 0, .reject(.notLocalCommand)),
    (70, "set a timer for an hour", 0, .reject(.invalidArgument)),
    (71, "5 minutes", 0, .reject(.notLocalCommand)),
    (72, "ten minutes timer", 0, .local(.timerStart(minutes: 10)))
]

private func assertRoute(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
    guard let row = routerCases.first(where: { $0.n == n }) else {
        XCTFail("no router case \(n)", file: file, line: line)
        return
    }
    let context: RouterContext
    switch row.ctx {
    case 1: context = RouterContext(hermesLaneAvailable: true)
    case 2: context = RouterContext(agentBusy: true)
    default: context = RouterContext()
    }
    XCTAssertEqual(IntentRouter.route(row.utterance, context: context), row.expected,
                   "router case \(n): \(row.utterance)", file: file, line: line)
}

final class IntentRouterTests: XCTestCase {
    func testRouter_1_play() { assertRoute(1) }
    func testRouter_2_pauseMusicPlease() { assertRoute(2) }
    func testRouter_3_stopPausesMedia() { assertRoute(3) }
    func testRouter_4_stopWhileAgentBusyCancelsTurn() { assertRoute(4) }
    func testRouter_5_cancelAloneIsAmbiguous() { assertRoute(5) }
    func testRouter_6_cancelWhileAgentBusyCancelsTurn() { assertRoute(6) }
    func testRouter_7_cancelTimer() { assertRoute(7) }
    func testRouter_8_abortAgent() { assertRoute(8) }
    func testRouter_9_abortTheAgent() { assertRoute(9) }
    func testRouter_10_nextSong() { assertRoute(10) }
    func testRouter_11_skip() { assertRoute(11) }
    func testRouter_12_previousTrack() { assertRoute(12) }
    func testRouter_13_volumeThirty() { assertRoute(13) }
    func testRouter_14_setTheVolumeToThirtyPercent() { assertRoute(14) }
    func testRouter_15_volumeToTwentyFive() { assertRoute(15) }
    func testRouter_16_volumeTwentyFiveHyphen() { assertRoute(16) }
    func testRouter_17_volumeToHundred() { assertRoute(17) }
    func testRouter_18_volumeZero() { assertRoute(18) }
    func testRouter_19_volumeOutOfRange() { assertRoute(19) }
    func testRouter_20_volumeAloneIsAmbiguous() { assertRoute(20) }
    func testRouter_21_volumeToWithoutNumber() { assertRoute(21) }
    func testRouter_22_setVolumeToBanana() { assertRoute(22) }
    func testRouter_23_louder() { assertRoute(23) }
    func testRouter_24_turnItDownABit() { assertRoute(24) }
    func testRouter_25_volumeUpALittle() { assertRoute(25) }
    func testRouter_26_quieter() { assertRoute(26) }
    func testRouter_27_mute() { assertRoute(27) }
    func testRouter_28_unMute() { assertRoute(28) }
    func testRouter_29_openSafari() { assertRoute(29) }
    func testRouter_30_openTheActivityMonitorApp() { assertRoute(30) }
    func testRouter_31_launchVSCode() { assertRoute(31) }
    func testRouter_32_openSofari() { assertRoute(32) }
    func testRouter_33_openAloneIsAmbiguous() { assertRoute(33) }
    func testRouter_34_openThePodBayDoors() { assertRoute(34) }
    func testRouter_35_longOpenGoesRemote() { assertRoute(35) }
    func testRouter_36_timerTenMinutes() { assertRoute(36) }
    func testRouter_37_setATimerForFiveMinutes() { assertRoute(37) }
    func testRouter_38_setA25MinuteTimer() { assertRoute(38) }
    func testRouter_39_timerZeroMinutes() { assertRoute(39) }
    func testRouter_40_timerFiveHundredMinutes() { assertRoute(40) }
    func testRouter_41_timerAloneIsAmbiguous() { assertRoute(41) }
    func testRouter_42_timerTenHasNoUnit() { assertRoute(42) }
    func testRouter_43_putarMusik() { assertRoute(43) }
    func testRouter_44_jeda() { assertRoute(44) }
    func testRouter_45_laguBerikutnya() { assertRoute(45) }
    func testRouter_46_volumeKeLimaPuluhPersen() { assertRoute(46) }
    func testRouter_47_aturVolumeJadiTujuhPuluh() { assertRoute(47) }
    func testRouter_48_kecilkanVolumeSedikit() { assertRoute(48) }
    func testRouter_49_bukaAplikasiKalender() { assertRoute(49) }
    func testRouter_50_setelTimerLimaBelasMenit() { assertRoute(50) }
    func testRouter_51_batalkanTimer() { assertRoute(51) }
    func testRouter_52_batalkanAgent() { assertRoute(52) }
    func testRouter_53_weatherNotLocal() { assertRoute(53) }
    func testRouter_54_weatherGoesRemote() { assertRoute(54) }
    func testRouter_55_empty() { assertRoute(55) }
    func testRouter_56_whitespaceOnly() { assertRoute(56) }
    func testRouter_57_umOnly() { assertRoute(57) }
    func testRouter_58_tooLong() { assertRoute(58) }
    func testRouter_59_playSomethingNotLocal() { assertRoute(59) }
    func testRouter_60_playSomethingGoesRemote() { assertRoute(60) }
    func testRouter_61_pauseTheScanGoesRemote() { assertRoute(61) }
    func testRouter_62_stopTheScanNotLocal() { assertRoute(62) }
    func testRouter_63_heyDesnotchVolume() { assertRoute(63) }
    func testRouter_64_tolongBukaSafariDong() { assertRoute(64) }
    func testRouter_65_pauseABitNotLocal() { assertRoute(65) }
    func testRouter_66_muteTheTVNotLocal() { assertRoute(66) }
    func testRouter_67_volumeUpWhileAgentBusy() { assertRoute(67) }
    func testRouter_68_hentikanWhileAgentBusy() { assertRoute(68) }
    func testRouter_69_hentikanAloneNotLocal() { assertRoute(69) }
    func testRouter_70_setATimerForAnHour() { assertRoute(70) }
    func testRouter_71_fiveMinutesNotATimer() { assertRoute(71) }
    func testRouter_72_tenMinutesTimer() { assertRoute(72) }

    func testRouterOpenUpSafariUsesTheLongestVerb() {
        let decision = IntentRouter.route("open up safari", context: RouterContext())
        XCTAssertEqual(decision, .local(.openApp(bundleID: "com.apple.Safari", name: "Safari")))
    }

    func testRouterBukaAplikasiAloneIsUnknownApp() {
        let decision = IntentRouter.route("buka aplikasi", context: RouterContext())
        XCTAssertEqual(decision, .reject(.unknownApp))
    }
}
