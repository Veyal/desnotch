import Foundation
import XCTest

/// Deterministic replacements for fixed-duration sleeps in tests. Both helpers enqueue a
/// sentinel behind work that is already queued on the main queue (FIFO), so by the time
/// they return every earlier delivery has run - no timing assumptions, no wasted wait.

/// Suspends until every operation already queued on `OperationQueue.main` has run. Use after
/// posting to a `NotificationCenter` observer registered with `queue: .main`.
func drainMainOperationQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        OperationQueue.main.addOperation { continuation.resume() }
    }
}

extension XCTestCase {
    /// Spins the run loop until every block already dispatched to the main queue has run.
    /// Use after changing a value observed through Combine's `receive(on: DispatchQueue.main)`.
    @MainActor
    func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }
}
