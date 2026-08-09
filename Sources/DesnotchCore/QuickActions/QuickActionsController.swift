import Foundation
import os

/// Owns session-scoped system quick actions exposed by the pill and status menu.
///
/// Display-awake launches a private `caffeinate -d` subprocess. `-w` ties the
/// assertion to desnotch's lifetime as a crash/signal safety net; toggling it off
/// terminates only this owned process, never another caffeinate the user started.
@MainActor
public final class QuickActionsController: ObservableObject {
    @Published public private(set) var isDisplayAwake = false

    private let logger = Logger(subsystem: "com.desnotch.app", category: "QuickActions")
    private let executableURL: URL
    private let arguments: [String]
    private var displayAwakeProcess: Process?

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

    public func toggleDisplayAwake() {
        isDisplayAwake ? stopDisplayAwake() : startDisplayAwake()
    }

    public func stopDisplayAwake() {
        let process = displayAwakeProcess
        displayAwakeProcess = nil
        isDisplayAwake = false
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func startDisplayAwake() {
        guard displayAwakeProcess == nil else { return }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminatedProcess in
            let pid = terminatedProcess.processIdentifier
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleDisplayAwakeTermination(pid: pid)
                }
            }
        }

        do {
            try process.run()
            displayAwakeProcess = process
            isDisplayAwake = true
        } catch {
            logger.error("Failed to launch caffeinate: \(error.localizedDescription, privacy: .public).")
        }
    }

    private func handleDisplayAwakeTermination(pid: Int32) {
        guard displayAwakeProcess?.processIdentifier == pid else { return }
        displayAwakeProcess = nil
        isDisplayAwake = false
    }

    deinit {
        if displayAwakeProcess?.isRunning == true {
            displayAwakeProcess?.terminate()
        }
    }
}
