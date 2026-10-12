import Foundation

/// One scheduled timer. Keying by `(kind, generation)` lives in the coordinator, not here.
@MainActor
protocol VoiceTimerHandle: AnyObject {
    func cancel()
}

/// Un-keyed scheduler: each call is an independent non-repeating timer.
@MainActor
protocol VoiceTimerScheduling: AnyObject {
    func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> VoiceTimerHandle
}

/// Run-loop timer on `.common`, matching `FocusTimerController`. The block is not
/// main-actor isolated, so the action is entered explicitly (the older CI compiler
/// rejects a bare call of a main-actor closure from that block).
@MainActor
final class RunLoopTimerScheduler: VoiceTimerScheduling {
    func schedule(after seconds: Double, _ action: @escaping @MainActor () -> Void) -> VoiceTimerHandle {
        let handle = RunLoopTimerHandle()
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        handle.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return handle
    }
}

@MainActor
private final class RunLoopTimerHandle: VoiceTimerHandle {
    var timer: Timer?

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
