import CoreAudio
import CoreMediaIO
import Foundation

/// Detects whether any process is using a microphone or camera, for the pill's
/// privacy dots (the camera literally lives in the notch). Uses the devices'
/// "is running somewhere" properties - no capture permission needed, since we
/// never access the devices, only their state. Polled: neither API offers a
/// notification for other-process usage.
@MainActor
public final class MediaUseMonitor: ObservableObject {
    @Published public private(set) var micInUse = false
    @Published public private(set) var cameraInUse = false

    private let pollInterval: TimeInterval = 5
    private var pollTask: Task<Void, Never>?

    public init() {
        startPolling()
    }

    private func startPolling() {
        let interval = pollInterval
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let enabled = await MainActor.run { SettingsStore.shared.micCameraIndicatorEnabled }
                let mic = enabled && Self.anyMicrophoneRunning()
                let camera = enabled && Self.anyCameraRunning()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.micInUse != mic { self.micInUse = mic }
                    if self.cameraInUse != camera { self.cameraInUse = camera }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    // MARK: - CoreAudio (microphone)

    nonisolated private static func anyMicrophoneRunning() -> Bool {
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

        for device in devices where hasInputStreams(device) {
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

    nonisolated private static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    // MARK: - CoreMediaIO (camera)

    nonisolated private static func anyCameraRunning() -> Bool {
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
    }
}
