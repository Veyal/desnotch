// A minimal stand-in for Apple's XCTest, for machines that only have the Command Line Tools
// (no XCTest framework). It implements just the API surface the desnotch tests use, plus a
// recorder the generated runner reads. It is NOT shipped and NOT used by CI (CI runs the real
// XCTest through `swift test`). See docs/voice/PLAN.md, "Build, test and harness commands".

@_exported import Foundation
#if canImport(AppKit)
@_exported import AppKit
#endif

// MARK: - Failure recorder

public final class XCTHarness: @unchecked Sendable {
    public static let shared = XCTHarness()
    private let lock = NSLock()
    private var failures: [String] = []
    private var assertions = 0

    public func record(_ message: String, file: StaticString, line: UInt) {
        lock.lock()
        failures.append("\(file):\(line): \(message)")
        lock.unlock()
    }

    public func countAssertion() {
        lock.lock()
        assertions += 1
        lock.unlock()
    }

    public func takeFailures() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let taken = failures
        failures = []
        return taken
    }

    public var assertionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return assertions
    }
}

// MARK: - XCTestCase

public struct XCTSkip: Error {
    public init(_ message: String = "") {}
}

open class XCTestExpectation {
    public let expectationDescription: String
    public var expectedFulfillmentCount = 1
    public var isInverted = false
    private var fulfilled = 0

    public init(description: String = "") {
        expectationDescription = description
    }

    open func fulfill() {
        fulfilled += 1
    }

    var isSatisfied: Bool { fulfilled >= expectedFulfillmentCount }
}

open class XCTestCase {
    public required init() {}

    open func setUp() {}
    open func tearDown() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}
    open class func setUp() {}
    open class func tearDown() {}

    public var continueAfterFailure = true
    private var teardownBlocks: [() -> Void] = []

    public func addTeardownBlock(_ block: @escaping () -> Void) {
        teardownBlocks.append(block)
    }

    public func runTeardownBlocks() {
        for block in teardownBlocks.reversed() { block() }
        teardownBlocks = []
    }

    public func expectation(description: String) -> XCTestExpectation {
        XCTestExpectation(description: description)
    }

    public enum WaitResult { case completed, timedOut }

    @discardableResult
    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval) -> WaitResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !expectations.allSatisfy(Self.isMet) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return report(expectations)
    }

    @discardableResult
    public func fulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval) async -> WaitResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !expectations.allSatisfy(Self.isMet) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return report(expectations)
    }

    private static func isMet(_ expectation: XCTestExpectation) -> Bool {
        expectation.isInverted ? !expectation.isSatisfied : expectation.isSatisfied
    }

    private func report(_ expectations: [XCTestExpectation]) -> WaitResult {
        var ok = true
        for expectation in expectations where !Self.isMet(expectation) {
            ok = false
            XCTFail("Expectation not met: \(expectation.expectationDescription)")
        }
        return ok ? .completed : .timedOut
    }
}

// MARK: - Assertions

private func fail(_ prefix: String, _ message: String, _ file: StaticString, _ line: UInt) {
    let suffix = message.isEmpty ? "" : " - \(message)"
    XCTHarness.shared.record(prefix + suffix, file: file, line: line)
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTHarness.shared.countAssertion()
    fail("XCTFail", message, file, line)
}

public func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        if try !expression() { fail("XCTAssertTrue failed", message(), file, line) }
    } catch {
        fail("XCTAssertTrue threw \(error)", message(), file, line)
    }
}

public func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        if try expression() { fail("XCTAssertFalse failed", message(), file, line) }
    } catch {
        fail("XCTAssertFalse threw \(error)", message(), file, line)
    }
}

public func XCTAssertNil(
    _ expression: @autoclosure () throws -> Any?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        let value = try expression()
        if value != nil { fail("XCTAssertNil failed: \(String(describing: value!))", message(), file, line) }
    } catch {
        fail("XCTAssertNil threw \(error)", message(), file, line)
    }
}

public func XCTAssertNotNil(
    _ expression: @autoclosure () throws -> Any?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        if try expression() == nil { fail("XCTAssertNotNil failed", message(), file, line) }
    } catch {
        fail("XCTAssertNotNil threw \(error)", message(), file, line)
    }
}

public func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        let a = try expression1()
        let b = try expression2()
        if a != b { fail("XCTAssertEqual failed: (\(a)) is not equal to (\(b))", message(), file, line) }
    } catch {
        fail("XCTAssertEqual threw \(error)", message(), file, line)
    }
}

public func XCTAssertEqual<T: FloatingPoint>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    accuracy: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        let a = try expression1()
        let b = try expression2()
        if !(abs(a - b) <= accuracy) {
            fail("XCTAssertEqual failed: (\(a)) is not equal to (\(b)) +/- (\(accuracy))", message(), file, line)
        }
    } catch {
        fail("XCTAssertEqual threw \(error)", message(), file, line)
    }
}

public func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        let a = try expression1()
        let b = try expression2()
        if a == b { fail("XCTAssertNotEqual failed: (\(a)) is equal to (\(b))", message(), file, line) }
    } catch {
        fail("XCTAssertNotEqual threw \(error)", message(), file, line)
    }
}

public func XCTAssertIdentical(
    _ expression1: @autoclosure () throws -> AnyObject?,
    _ expression2: @autoclosure () throws -> AnyObject?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        if try expression1() !== expression2() { fail("XCTAssertIdentical failed", message(), file, line) }
    } catch {
        fail("XCTAssertIdentical threw \(error)", message(), file, line)
    }
}

private func compare<T: Comparable>(
    _ name: String,
    _ expression1: () throws -> T,
    _ expression2: () throws -> T,
    _ holds: (T, T) -> Bool,
    _ message: String,
    _ file: StaticString, _ line: UInt
) {
    XCTHarness.shared.countAssertion()
    do {
        let a = try expression1()
        let b = try expression2()
        if !holds(a, b) { fail("\(name) failed: (\(a)) vs (\(b))", message, file, line) }
    } catch {
        fail("\(name) threw \(error)", message, file, line)
    }
}

public func XCTAssertGreaterThan<T: Comparable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) { compare("XCTAssertGreaterThan", a, b, { $0 > $1 }, message(), file, line) }

public func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) { compare("XCTAssertGreaterThanOrEqual", a, b, { $0 >= $1 }, message(), file, line) }

public func XCTAssertLessThan<T: Comparable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) { compare("XCTAssertLessThan", a, b, { $0 < $1 }, message(), file, line) }

public func XCTAssertLessThanOrEqual<T: Comparable>(
    _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) { compare("XCTAssertLessThanOrEqual", a, b, { $0 <= $1 }, message(), file, line) }

public func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) {
    XCTHarness.shared.countAssertion()
    do {
        _ = try expression()
        fail("XCTAssertThrowsError failed: did not throw", message(), file, line)
    } catch {
        errorHandler(error)
    }
}

public func XCTAssertNoThrow<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTHarness.shared.countAssertion()
    do {
        _ = try expression()
    } catch {
        fail("XCTAssertNoThrow failed: threw \(error)", message(), file, line)
    }
}

public func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    XCTHarness.shared.countAssertion()
    if let value = try expression() { return value }
    fail("XCTUnwrap failed: value was nil", message(), file, line)
    throw XCTSkip("XCTUnwrap failed")
}

// MARK: - Runner support (used by the generated main.swift)

private final class AsyncDoneBox: @unchecked Sendable {
    var done = false
    var skipped = false
    var thrown: Error?
}

/// Runs tests one at a time on the main thread. Synchronous tests run directly (not inside a
/// dispatch block), so `wait(for:)` and `drainMainQueue()` can pump the main run loop exactly
/// as they do under Apple's XCTest. Async tests run in a main-actor task while the run loop spins.
public final class HarnessRunner {
    private let filter: String?
    private var passed = 0
    private var failed = 0
    private var failedNames: [String] = []

    public init(filter: String?) {
        self.filter = filter
    }

    private func wanted(_ full: String) -> Bool {
        guard let filter, !filter.isEmpty else { return true }
        return full.contains(filter)
    }

    public func runSync<T: XCTestCase>(_ type: T.Type, _ name: String, _ body: (T) throws -> Void) {
        let full = "\(type).\(name)"
        guard wanted(full) else { return }
        _ = XCTHarness.shared.takeFailures()
        let test = type.init()
        var skipped = false
        do {
            try test.setUpWithError()
            test.setUp()
            try body(test)
        } catch is XCTSkip {
            skipped = true
        } catch {
            XCTFail("threw \(error)")
        }
        finishTest(test, full, skipped)
    }

    public func runAsync<T: XCTestCase>(_ type: T.Type, _ name: String, _ body: @escaping @MainActor (T) async throws -> Void) {
        let full = "\(type).\(name)"
        guard wanted(full) else { return }
        _ = XCTHarness.shared.takeFailures()
        let test = type.init()
        let box = AsyncDoneBox()
        do {
            try test.setUpWithError()
            test.setUp()
        } catch {
            XCTFail("setUp threw \(error)")
        }
        nonisolated(unsafe) let unsafeTest = test
        Task { @MainActor in
            do {
                try await body(unsafeTest)
            } catch is XCTSkip {
                box.skipped = true
            } catch {
                box.thrown = error
            }
            box.done = true
        }
        while !box.done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        if let error = box.thrown { XCTFail("threw \(error)") }
        finishTest(test, full, box.skipped)
    }

    private func finishTest(_ test: XCTestCase, _ full: String, _ skipped: Bool) {
        test.tearDown()
        try? test.tearDownWithError()
        test.runTeardownBlocks()
        let failures = XCTHarness.shared.takeFailures()
        if failures.isEmpty {
            passed += 1
            print("ok   \(full)\(skipped ? " (skipped)" : "")")
        } else {
            failed += 1
            failedNames.append(full)
            print("FAIL \(full)")
            for failure in failures { print("       \(failure)") }
        }
    }

    public func finish() -> Int32 {
        print("")
        print("harness: \(passed) passed, \(failed) failed, \(XCTHarness.shared.assertionCount) assertions")
        if !failedNames.isEmpty { print("failed: " + failedNames.joined(separator: ", ")) }
        return failed == 0 ? 0 : 1
    }
}
