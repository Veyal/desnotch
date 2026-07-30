import AudioToolbox
import CoreAudio

/// Reads/writes the default output device's volume via CoreAudio, for the notch's
/// scroll-to-adjust gesture. `VirtualMainVolume` tracks the same value the volume keys
/// and menu-bar slider control (it follows the device's software/hardware volume as
/// appropriate), so no private API is needed.
public enum SystemVolume {
    public static func current() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var addr = volumeAddress()
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Clamped adjust; returns the new level (0...1), or nil if the device has no
    /// settable volume (e.g. some external DACs/displays).
    @discardableResult
    public static func adjust(by delta: Float) -> Float? {
        guard let device = defaultOutputDevice(), let cur = current() else { return nil }
        var addr = volumeAddress()
        var newValue = Float32(min(1, max(0, cur + delta)))
        let size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectSetPropertyData(device, &addr, 0, nil, size, &newValue) == noErr else { return nil }
        return Float(newValue)
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
