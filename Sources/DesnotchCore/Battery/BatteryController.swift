import Foundation
import IOKit.ps

/// Publishes internal-battery state for the pill's battery glance. Machines without a
/// battery (Mac mini, Studio, Pro) publish nil and the section never renders. Updates
/// arrive push-style from IOKit's power-source notification (no polling), and a
/// plug/unplug flips `isCharging`, which briefly auto-expands the pill as a toast.
@MainActor
public final class BatteryController: ObservableObject {
    public struct BatteryState: Equatable {
        public let percent: Int
        public let isCharging: Bool

        public init(percent: Int, isCharging: Bool) {
            self.percent = percent
            self.isCharging = isCharging
        }
    }

    @Published public private(set) var state: BatteryState?

    public let presentation: NotchPillPresentation
    private var runLoopSource: CFRunLoopSource?

    public init(presentation: NotchPillPresentation) {
        self.presentation = presentation
        refresh(toastOnPowerChange: false)

        // IOKit invokes the callback on the run loop it's scheduled on (main here).
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<BatteryController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                controller.refresh(toastOnPowerChange: true)
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
    }

    private func refresh(toastOnPowerChange: Bool) {
        let previous = state
        state = Self.readInternalBattery()
        if toastOnPowerChange,
            SettingsStore.shared.batteryEnabled,
            let previous, let current = state,
            previous.isCharging != current.isCharging
        {
            presentation.flashOpen(for: 2.0)
        }
    }

    private static func readInternalBattery() -> BatteryState? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = info[kIOPSCurrentCapacityKey] as? Int,
                let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            return BatteryState(percent: Int((Double(current) / Double(max) * 100).rounded()), isCharging: charging)
        }
        return nil
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }
}
