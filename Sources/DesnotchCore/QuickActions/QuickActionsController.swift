import Combine
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
    public let dictation: DictationController
    public let agentCommand: AgentCommandController

    private let logger = Logger(subsystem: "com.desnotch.app", category: "QuickActions")
    private let executableURL: URL
    private let arguments: [String]
    private var displayAwakeProcess: Process?
    private var cancellables: Set<AnyCancellable> = []

    public convenience init() {
        let keyStore = SpeechKeychainStore()
        let dictation = DictationController(
            recorder: SpeechRecorder(),
            transcriberProvider: {
                let settings = SettingsStore.shared
                guard let baseURL = Self.validProviderURL(settings.transcriptionBaseURL) else {
                    return UnavailableSpeechTranscriber(message: "Enter a valid transcription provider URL in Settings.")
                }
                let configuredModel = settings.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
                return SpeechTranscriptionClient(
                    baseURL: baseURL,
                    model: configuredModel.isEmpty ? SpeechTranscriptionClient.defaultModel : configuredModel,
                    apiKey: { keyStore.load() }
                )
            },
            paster: AccessibilityPasteController()
        )
        let auditURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.desnotch.app", isDirectory: true)
            .appendingPathComponent("agent-command-audit.jsonl")
        let settings = SettingsStore.shared
        let agent = AgentCommandController(
            cwd: Self.validWorkingDirectory(settings.agentWorkingDirectory)
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            backendSelection: settings.agentBackend,
            audit: AgentCommandAudit(url: auditURL),
            automaticReadOnly: settings.agentAutoRunReadOnly,
            timeout: settings.agentCommandTimeout,
            outputByteCap: Int(settings.agentOutputLimitKB * 1024)
        )
        self.init(
            executableURL: URL(fileURLWithPath: "/usr/bin/caffeinate"),
            arguments: Self.caffeinateArguments(parentPID: ProcessInfo.processInfo.processIdentifier),
            dictation: dictation,
            agentCommand: agent
        )
    }

    /// Internal injection point for deterministic process-lifecycle tests.
    convenience init(executableURL: URL, arguments: [String]) {
        let keyStore = SpeechKeychainStore(service: "com.desnotch.tests.openai")
        let dictation = DictationController(
            recorder: SpeechRecorder(),
            transcriber: SpeechTranscriptionClient(apiKey: { keyStore.load() }),
            paster: AccessibilityPasteController()
        )
        let agent = AgentCommandController(cwd: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        self.init(
            executableURL: executableURL,
            arguments: arguments,
            dictation: dictation,
            agentCommand: agent
        )
    }

    init(
        executableURL: URL,
        arguments: [String],
        dictation: DictationController,
        agentCommand: AgentCommandController
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.dictation = dictation
        self.agentCommand = agentCommand
        dictation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        agentCommand.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        dictation.onTranscript = { [weak self] mode, transcript in
            guard mode == .talkToAgent else { return }
            self?.sendToAgent(transcript)
        }
    }

    nonisolated static func caffeinateArguments(parentPID: Int32) -> [String] {
        ["-d", "-w", String(parentPID)]
    }

    public func toggleDisplayAwake() {
        isDisplayAwake ? stopDisplayAwake() : startDisplayAwake()
    }

    public func toggleDictation() { toggleVoiceAction(.dictate) }
    public func toggleTalkToAgent() { toggleVoiceAction(.talkToAgent) }

    public func cancelVoiceActions() {
        dictation.cancel()
        agentCommand.cancel()
    }

    public func shutdownVoiceActions(timeout: TimeInterval = 2) {
        dictation.cancel()
        agentCommand.shutdownOwnedProcesses(timeout: timeout)
    }

    public func confirmAgentCommand() { agentCommand.confirm() }

    public func requestPasteAccessibilityPermission() -> Bool {
        dictation.requestAccessibilityPermission()
    }

    private func toggleVoiceAction(_ mode: DictationMode) {
        switch dictation.state {
        case .recording(let activeMode) where activeMode == mode:
            dictation.stop()
        case .requestingPermission, .recording, .uploading:
            dictation.cancel()
        default:
            dictation.clearResult()
            dictation.start(mode: mode)
        }
    }

    private func sendToAgent(_ transcript: String) {
        let settings = SettingsStore.shared
        guard let cwd = Self.validWorkingDirectory(settings.agentWorkingDirectory) else {
            agentCommand.failConfiguration("Choose an existing agent working directory in Settings.")
            return
        }
        agentCommand.configure(
            cwd: cwd,
            backend: settings.agentBackend,
            automaticReadOnly: settings.agentAutoRunReadOnly,
            timeout: settings.agentCommandTimeout,
            outputByteCap: Int(settings.agentOutputLimitKB * 1024)
        )
        agentCommand.submit(transcribedPrompt: transcript)
    }

    nonisolated static func validProviderURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), SpeechTranscriptionClient.isAllowedProviderURL(url) else { return nil }
        return url
    }

    nonisolated static func validWorkingDirectory(_ value: String) -> URL? {
        let expanded = NSString(string: value).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return url
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

private struct UnavailableSpeechTranscriber: SpeechTranscribing {
    let message: String
    func transcribe(fileURL: URL) async throws -> String {
        throw UnavailableSpeechTranscriberError(message: message)
    }
}

private struct UnavailableSpeechTranscriberError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
