import Combine
import Foundation
import os

/// Owns the optional, session-scoped display-awake assertion exposed in the status menu.
///
/// The owned `caffeinate -d` subprocess uses `-w` to tie itself to desnotch's
/// lifetime as a crash/signal safety net. Toggling it off terminates only this
/// process, never another caffeinate process the user started.
@MainActor
public final class DisplayAwakeController: ObservableObject {
    @Published public private(set) var isDisplayAwake = false

    private let logger = Logger(subsystem: "com.desnotch.app", category: "DisplayAwake")
    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?

    public convenience init() {
        self.init(
            executableURL: URL(fileURLWithPath: "/usr/bin/caffeinate"),
            arguments: Self.caffeinateArguments(parentPID: ProcessInfo.processInfo.processIdentifier)
        )
    }

    /// Internal injection point for deterministic process-lifecycle tests.
    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    nonisolated static func caffeinateArguments(parentPID: Int32) -> [String] {
        ["-d", "-w", String(parentPID)]
    }

    public func toggle() {
        isDisplayAwake ? stop() : start()
    }

    public func stop() {
        let ownedProcess = process
        process = nil
        isDisplayAwake = false
        if ownedProcess?.isRunning == true {
            ownedProcess?.terminate()
        }
    }

    private func start() {
        guard process == nil else { return }

        let ownedProcess = Process()
        ownedProcess.executableURL = executableURL
        ownedProcess.arguments = arguments
        ownedProcess.standardInput = FileHandle.nullDevice
        ownedProcess.standardOutput = FileHandle.nullDevice
        ownedProcess.standardError = FileHandle.nullDevice
        ownedProcess.terminationHandler = { [weak self] terminatedProcess in
            let pid = terminatedProcess.processIdentifier
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleTermination(pid: pid)
                }
            }
        }

        do {
            try ownedProcess.run()
            process = ownedProcess
            isDisplayAwake = true
        } catch {
            logger.error("Failed to launch caffeinate: \(error.localizedDescription, privacy: .public).")
        }
    }

    private func handleTermination(pid: Int32) {
        guard process?.processIdentifier == pid else { return }
        process = nil
        isDisplayAwake = false
    }

    deinit {
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}
