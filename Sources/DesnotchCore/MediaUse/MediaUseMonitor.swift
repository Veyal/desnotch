import Combine
import CoreAudio
import CoreMediaIO
import Foundation

/// Detects whether any process is using a microphone or camera, for the pill's
/// privacy dots (the camera literally lives in the notch). Uses the devices'
/// "is running somewhere" properties - no capture permission needed, since we
/// never access the devices, only their state.
///
/// Push-driven where the OS allows it: both CoreAudio and CoreMediaIO post a property
/// notification when a device's "is running somewhere" flips (and when the device list
/// changes), so `HardwareMediaUseSource` registers listeners and the monitor re-probes only on
/// a callback - an idle Mac does no periodic work. If registering the listeners fails, the
/// 5s poll loop (stretched by `PollingActivity`) remains as the fallback. Like every loop it
/// stops while the setting is off or nobody can see the result (displays/system asleep).
@MainActor
public final class MediaUseMonitor: ObservableObject {
    @Published public private(set) var micInUse = false
    @Published public private(set) var cameraInUse = false

    private let pollInterval: TimeInterval
    private let settings: SettingsStore
    private let activity: PollingActivity
    private let probe: @Sendable () -> (mic: Bool, camera: Bool)
    /// nil = poll only (tests, and the fallback when registration fails).
    private let changeSource: MediaUseChangeSource?
    private var isListening = false
    private var probeInFlight = false
    private var probeDirty = false
    private var pollTask: Task<Void, Never>?
    private var isEnabled = false
    private var isSuspended = false
    private var cancellables = Set<AnyCancellable>()

    public convenience init() {
        self.init(settings: .shared, activity: .shared, changeSource: HardwareMediaUseSource())
    }

    /// Internal injection point so tests can drive start/stop without touching hardware.
    init(
        settings: SettingsStore,
        activity: PollingActivity,
        pollInterval: TimeInterval = 5,
        changeSource: MediaUseChangeSource? = nil,
        probe: @escaping @Sendable () -> (mic: Bool, camera: Bool) = {
            (MediaUseMonitor.anyMicrophoneRunning(), MediaUseMonitor.anyCameraRunning())
        }
    ) {
        self.settings = settings
        self.activity = activity
        self.pollInterval = pollInterval
        self.changeSource = changeSource
        self.probe = probe

        // Polls only while the indicator is enabled and someone could see it, like
        // `ClipboardController` follows its setting instead of polling a flag.
        settings.$micCameraIndicatorEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.isEnabled = enabled
                if !enabled { self.apply((mic: false, camera: false)) }
                self.updatePolling()
            }
            .store(in: &cancellables)
        activity.$isSuspended
            .removeDuplicates()
            .sink { [weak self] suspended in
                self?.isSuspended = suspended
                self?.updatePolling()
            }
            .store(in: &cancellables)
    }

    /// Internal so tests can assert the loop follows the setting and the sleep gate.
    var isPolling: Bool { pollTask != nil }
    /// Internal so tests can assert the push path replaces the poll loop.
    var isListeningForChanges: Bool { isListening }

    private func updatePolling() {
        guard isEnabled && !isSuspended else {
            pollTask?.cancel()
            pollTask = nil
            stopListening()
            return
        }
        guard pollTask == nil, !isListening else { return }
        if let changeSource, startListening(changeSource) { return }
        startPollLoop()
    }

    private func startPollLoop() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Registers the OS listeners and takes an initial reading. False (nothing registered)
    /// leaves the caller to poll instead.
    private func startListening(_ source: MediaUseChangeSource) -> Bool {
        let started = source.start(
            onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.reprobe() }
            },
            onFailure: { [weak self] in
                Task { @MainActor [weak self] in self?.fallBackToPolling() }
            }
        )
        guard started else { return false }
        isListening = true
        reprobe()
        return true
    }

    private func stopListening() {
        guard isListening else { return }
        changeSource?.stop()
        isListening = false
        probeDirty = false
    }

    /// A listener could not be (re)registered while running, e.g. after a hot-plug: the push
    /// path can no longer be trusted to be complete, so poll instead.
    private func fallBackToPolling() {
        guard isListening else { return }
        stopListening()
        if isEnabled && !isSuspended { startPollLoop() }
    }

    /// One coalesced probe off the main actor, run on a change callback: a burst of callbacks
    /// (a device list change fires several) collapses into one more probe, not one each.
    private func reprobe() {
        guard isListening else { return }
        guard !probeInFlight else {
            probeDirty = true
            return
        }
        probeInFlight = true
        let probe = self.probe
        Task { [weak self] in
            let state = await Task.detached(priority: .utility) { probe() }.value
            guard let self else { return }
            self.probeInFlight = false
            if self.isListening { self.apply(state) }
            if self.probeDirty {
                self.probeDirty = false
                self.reprobe()
            }
        }
    }

    /// One probe off the main actor; returns how long to wait before the next one.
    private func pollOnce() async -> TimeInterval {
        let probe = self.probe
        let state = await Task.detached(priority: .utility) { probe() }.value
        guard !Task.isCancelled else { return pollInterval }
        apply(state)
        return activity.scaled(pollInterval)
    }

    private func apply(_ state: (mic: Bool, camera: Bool)) {
        if micInUse != state.mic { micInUse = state.mic }
        if cameraInUse != state.camera { cameraInUse = state.camera }
    }

    // MARK: - CoreAudio (microphone)

    nonisolated static func anyMicrophoneRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
            size > 0
        else { return false }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return false }

        // Virtual loopback drivers (BlackHole & co.) report "running somewhere"
        // permanently and would pin the mic dot on; they aren't a real microphone.
        for device in devices where hasInputStreams(device) && !isVirtualTransport(device) {
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &runningAddr, 0, nil, &runningSize, &running) == noErr,
                running != 0
            {
                return true
            }
        }
        return false
    }

    nonisolated static func isVirtualTransport(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeVirtual
    }

    nonisolated static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    // MARK: - CoreMediaIO (camera)

    nonisolated static func anyCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0,
            size > 0
        else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == 0
        else { return false }

        for device in devices {
            var runningAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var running: UInt32 = 0
            let runningSize = UInt32(MemoryLayout<UInt32>.size)
            var usedSize: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &runningAddr, 0, nil, runningSize, &usedSize, &running) == 0,
                running != 0
            {
                return true
            }
        }
        return false
    }

    deinit {
        pollTask?.cancel()
        changeSource?.stop()
    }
}

/// Delivers "a mic or camera may have started/stopped" callbacks, so the monitor re-probes
/// on demand instead of on a timer.
protocol MediaUseChangeSource: AnyObject {
    /// Registers the listeners. `onChange` may fire on any thread. `onFailure` fires if a
    /// later (re)registration fails, after which no more `onChange` calls can be relied on.
    /// Returns false when nothing could be registered (the caller polls instead).
    func start(onChange: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable () -> Void) -> Bool
    func stop()
}

/// CoreAudio + CoreMediaIO property listeners: "is running somewhere" on every real input
/// device / camera, plus the hardware device lists so hot-plugged devices are picked up.
/// All registration state lives on one serial queue, which is also the callback queue.
final class HardwareMediaUseSource: MediaUseChangeSource, @unchecked Sendable {
    private struct AudioRegistration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct VideoRegistration {
        let object: CMIOObjectID
        var address: CMIOObjectPropertyAddress
        let block: CMIOObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "desnotch.mediause")
    private var onChange: (@Sendable () -> Void)?
    private var onFailure: (@Sendable () -> Void)?
    private var systemAudio: AudioRegistration?
    private var systemVideo: VideoRegistration?
    private var audioDevices: [AudioRegistration] = []
    private var videoDevices: [VideoRegistration] = []
    private var isRunning = false

    func start(onChange: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable () -> Void) -> Bool {
        queue.sync {
            guard !isRunning else { return true }
            self.onChange = onChange
            self.onFailure = onFailure
            isRunning = true
            guard registerSystemListeners(), rebuildDeviceListeners() else {
                teardown()
                return false
            }
            return true
        }
    }

    func stop() {
        queue.sync { teardown() }
    }

    // MARK: Registration (queue-confined)

    private func registerSystemListeners() -> Bool {
        var audioAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let audioBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &audioAddress, queue, audioBlock
        ) == noErr else { return false }
        systemAudio = AudioRegistration(
            object: AudioObjectID(kAudioObjectSystemObject), address: audioAddress, block: audioBlock
        )

        var videoAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let videoBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
        guard CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &videoAddress, queue, videoBlock
        ) == 0 else { return false }
        systemVideo = VideoRegistration(
            object: CMIOObjectID(kCMIOObjectSystemObject), address: videoAddress, block: videoBlock
        )
        return true
    }

    /// Runs on `queue` (it is the listener queue).
    private func devicesChanged() {
        guard isRunning else { return }
        if rebuildDeviceListeners() {
            onChange?()
        } else {
            let failure = onFailure
            teardown()
            failure?()
        }
    }

    /// Drops every per-device listener and re-adds one per current input device / camera.
    /// False if any registration failed (a partial set would miss events).
    private func rebuildDeviceListeners() -> Bool {
        removeDeviceListeners()

        var audioRunning = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for device in Self.audioDeviceIDs()
        where MediaUseMonitor.hasInputStreams(device) && !MediaUseMonitor.isVirtualTransport(device) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
            guard AudioObjectAddPropertyListenerBlock(device, &audioRunning, queue, block) == noErr else {
                return false
            }
            audioDevices.append(AudioRegistration(object: device, address: audioRunning, block: block))
        }

        var videoRunning = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        for device in Self.videoDeviceIDs() {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
            guard CMIOObjectAddPropertyListenerBlock(device, &videoRunning, queue, block) == 0 else {
                return false
            }
            videoDevices.append(VideoRegistration(object: device, address: videoRunning, block: block))
        }
        return true
    }

    private func removeDeviceListeners() {
        for var registration in audioDevices {
            AudioObjectRemovePropertyListenerBlock(
                registration.object, &registration.address, queue, registration.block
            )
        }
        for var registration in videoDevices {
            CMIOObjectRemovePropertyListenerBlock(
                registration.object, &registration.address, queue, registration.block
            )
        }
        audioDevices = []
        videoDevices = []
    }

    private func teardown() {
        guard isRunning else { return }
        isRunning = false
        removeDeviceListeners()
        if var registration = systemAudio {
            AudioObjectRemovePropertyListenerBlock(
                registration.object, &registration.address, queue, registration.block
            )
        }
        if var registration = systemVideo {
            CMIOObjectRemovePropertyListenerBlock(
                registration.object, &registration.address, queue, registration.block
            )
        }
        systemAudio = nil
        systemVideo = nil
        onChange = nil
        onFailure = nil
    }

    // MARK: Device lists

    private static func audioDeviceIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func videoDeviceIDs() -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0,
            size > 0
        else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == 0
        else { return [] }
        return devices
    }

    deinit {
        // Not `queue.sync`: the last reference can be released from inside a callback that is
        // already running on `queue`, which would deadlock. Nothing else can touch the state
        // once deinit runs.
        teardown()
    }
}
