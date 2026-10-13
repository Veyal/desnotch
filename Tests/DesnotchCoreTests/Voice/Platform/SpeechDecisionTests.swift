import XCTest
@testable import DesnotchCore

final class SpeechDecisionTests: XCTestCase {
    func testRow1NonNilTextPartialNoError() {
        let result = SpeechDecision.event(
            text: "testing partial",
            isFinal: false,
            errorPresent: false,
            endAudioCalled: false,
            lastPartial: ""
        )
        XCTAssertEqual(result, .partial("testing partial"))

        let resultWithEndAudio = SpeechDecision.event(
            text: "testing partial 2",
            isFinal: false,
            errorPresent: false,
            endAudioCalled: true,
            lastPartial: ""
        )
        XCTAssertEqual(resultWithEndAudio, .partial("testing partial 2"))
    }

    func testRow2NonNilTextFinalNoError() {
        let result = SpeechDecision.event(
            text: "testing final",
            isFinal: true,
            errorPresent: false,
            endAudioCalled: false,
            lastPartial: ""
        )
        XCTAssertEqual(result, .final("testing final"))

        let resultWithEndAudio = SpeechDecision.event(
            text: "testing final 2",
            isFinal: true,
            errorPresent: false,
            endAudioCalled: true,
            lastPartial: ""
        )
        XCTAssertEqual(resultWithEndAudio, .final("testing final 2"))
    }

    func testRow3ErrorPresentWhenEndAudioCalledEmitsFinalWithLastPartial() {
        let resultWithPartial = SpeechDecision.event(
            text: "new text",
            isFinal: false,
            errorPresent: true,
            endAudioCalled: true,
            lastPartial: "previous partial"
        )
        XCTAssertEqual(resultWithPartial, .final("previous partial"))

        let resultWithEmptyPartial = SpeechDecision.event(
            text: nil,
            isFinal: false,
            errorPresent: true,
            endAudioCalled: true,
            lastPartial: ""
        )
        XCTAssertEqual(resultWithEmptyPartial, .final(""))
    }

    func testRow4ErrorPresentWhenEndAudioNotCalledEmitsFailedUnavailable() {
        let result = SpeechDecision.event(
            text: "ignored text",
            isFinal: false,
            errorPresent: true,
            endAudioCalled: false,
            lastPartial: "ignored partial"
        )
        XCTAssertEqual(result, .failed(.unavailable(.recognizer)))
    }

    func testRow5NilTextWithNoErrorEmitsNil() {
        let resultNotFinal = SpeechDecision.event(
            text: nil,
            isFinal: false,
            errorPresent: false,
            endAudioCalled: false,
            lastPartial: "cached"
        )
        XCTAssertNil(resultNotFinal)

        let resultFinal = SpeechDecision.event(
            text: nil,
            isFinal: true,
            errorPresent: false,
            endAudioCalled: true,
            lastPartial: "cached"
        )
        XCTAssertNil(resultFinal)
    }

    func testIsTerminalAllFiveCases() {
        XCTAssertFalse(SpeechDecision.isTerminal(.captureStarted))
        XCTAssertFalse(SpeechDecision.isTerminal(.level(0.5)))
        XCTAssertFalse(SpeechDecision.isTerminal(.partial("some text")))
        XCTAssertTrue(SpeechDecision.isTerminal(.final("done text")))
        XCTAssertTrue(SpeechDecision.isTerminal(.failed(.unavailable(.recognizer))))
    }
}

final class CaptureBookTests: XCTestCase {
    func testTakeWithStaleTokenReturnsNilAndChangesNothing() {
        var book = CaptureBook<String>()
        let (token, replaced) = book.begin(payload: "payload1")
        XCTAssertNil(replaced)
        XCTAssertEqual(book.payload(forToken: token), "payload1")

        let staleResult = book.take(token: 999_999)
        XCTAssertNil(staleResult)
        XCTAssertEqual(book.payload(forToken: token), "payload1")
    }

    func testTakeTwiceReturnsPayloadOnce() {
        var book = CaptureBook<String>()
        let (token, _) = book.begin(payload: "payload1")

        let firstTake = book.take(token: token)
        XCTAssertEqual(firstTake, "payload1")

        let secondTake = book.take(token: token)
        XCTAssertNil(secondTake)
        XCTAssertNil(book.payload(forToken: token))
    }

    func testBeginWhileCaptureIsActiveHandsBackOldPayload() {
        var book = CaptureBook<String>()
        let (token1, replaced1) = book.begin(payload: "first")
        XCTAssertNil(replaced1)
        XCTAssertEqual(book.payload(forToken: token1), "first")

        let (token2, replaced2) = book.begin(payload: "second")
        XCTAssertEqual(replaced2, "first")
        XCTAssertEqual(book.payload(forToken: token2), "second")
        XCTAssertNil(book.payload(forToken: token1))
    }

    private final class BookBox: @unchecked Sendable {
        let lock = NSLock()
        var book = CaptureBook<String>()
    }

    func testReentrancyWithoutDeadlockWhenFinishCalledOutsideLock() {
        let box = BookBox()
        let exp = expectation(description: "stream terminated")

        let (_, continuation) = AsyncStream<Void>.makeStream()

        box.lock.lock()
        let (token, _) = box.book.begin(payload: "reentrant-test")
        box.lock.unlock()

        continuation.onTermination = { _ in
            box.lock.lock()
            let reentrantResult = box.book.take(token: token)
            box.lock.unlock()
            if reentrantResult == nil {
                exp.fulfill()
            }
        }

        box.lock.lock()
        let taken = box.book.take(token: token)
        box.lock.unlock()

        XCTAssertEqual(taken, "reentrant-test")

        continuation.finish()

        wait(for: [exp], timeout: 2.0)
    }

    func testEngineStartRunsOnlyWhileTheCaptureIsCurrent() {
        XCTAssertEqual(SpeechDecision.afterEngineStart(isCurrent: true, endAudioCalled: false), .run)
        XCTAssertEqual(SpeechDecision.afterEngineStart(isCurrent: true, endAudioCalled: true), .stopTap)
        XCTAssertEqual(SpeechDecision.afterEngineStart(isCurrent: false, endAudioCalled: false), .discard)
        XCTAssertEqual(SpeechDecision.afterEngineStart(isCurrent: false, endAudioCalled: true), .discard)
    }

    /// The recognition callback can fail and take the capture before `start` installs the tap and
    /// starts the engine. The engine that `start` then brings up must be discarded, not left running.
    func testCaptureTakenBeforeEngineStartIsDiscarded() {
        var book = CaptureBook<String>()
        let token = book.begin(payload: "capture").token
        XCTAssertEqual(book.take(token: token), "capture")
        let action = SpeechDecision.afterEngineStart(
            isCurrent: book.payload(forToken: token) != nil,
            endAudioCalled: false
        )
        XCTAssertEqual(action, .discard)
    }

    func testCaptureReplacedBeforeEngineStartIsDiscarded() {
        var book = CaptureBook<String>()
        let first = book.begin(payload: "first").token
        _ = book.begin(payload: "second")
        let action = SpeechDecision.afterEngineStart(
            isCurrent: book.payload(forToken: first) != nil,
            endAudioCalled: false
        )
        XCTAssertEqual(action, .discard)
    }
}
