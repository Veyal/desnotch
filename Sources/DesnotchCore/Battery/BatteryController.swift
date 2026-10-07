import Foundation
import IOKit.ps

/// Publishes internal-battery state for the pill's battery glance. Machines without a
/// battery (Mac mini, Studio, Pro) publish nil and the section never renders. Updates
/// arrive push-style from IOKit's power-source notification (no polling), and a
/// plug/unplug flips `isPluggedIn`, which briefly auto-expands the pill as a toast. The toast
/// follows the power SOURCE, not the charging flag: `kIOPSIsChargingKey` also goes false on AC
/// when the battery is full or Optimized Battery Charging holds it, which is not an unplug.
@MainActor
public final class BatteryController: ObservableObject {
    public struct BatteryState: Equatable {
        public let percent: Int
        /// Actively taking charge (the bolt). False while full or paused on AC.
        public let isCharging: Bool
        /// Running from the power adapter, charging or not.
        public let isPluggedIn: Bool

        /// `isPluggedIn` defaults to `isCharging` (charging implies a cable).
        public init(percent: Int, isCharging: Bool, isPluggedIn: Bool? = nil) {
            self.percent = percent
            self.isCharging = isCharging
            self.isPluggedIn = isPluggedIn ?? isCharging
        }

        public enum PowerStatus: Equatable { case charging, pluggedIn, onBattery }

        public var powerStatus: PowerStatus {
            isCharging ? .charging : (isPluggedIn ? .pluggedIn : .onBattery)
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
            previous.isPluggedIn != current.isPluggedIn
        {
            presentation.flashOpen(
                announcement: PillAnnouncements.power(isPluggedIn: current.isPluggedIn, percent: current.percent),
                kind: .power
            )
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
            // Absent state key: assume the cable follows the charging flag.
            let pluggedIn = (info[kIOPSPowerSourceStateKey] as? String).map { $0 == kIOPSACPowerValue }
                ?? charging
            return BatteryState(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: charging, isPluggedIn: pluggedIn || charging
            )
        }
        return nil
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }
}
