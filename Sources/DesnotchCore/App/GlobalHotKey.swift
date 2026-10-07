import AppKit
import Carbon.HIToolbox
import Combine

/// A key plus modifier combination for the global show-notch shortcut.
public struct HotKeyBinding: Equatable {
    /// Carbon virtual key code (`kVK_ANSI_*`).
    public let keyCode: UInt32
    /// Carbon modifier mask (`cmdKey | optionKey | ...`).
    public let carbonModifiers: UInt32
    /// The key's printable label, for the settings and onboarding copy.
    public let keyLabel: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// Option-Command-N. Control+Option is avoided on purpose: it is VoiceOver's modifier.
    public static let `default` = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_N),
        carbonModifiers: UInt32(cmdKey | optionKey),
        keyLabel: "N"
    )

    /// "⌃⌥⇧⌘N" style label in the order macOS menus use.
    public var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    /// The same modifiers as an `NSEvent.ModifierFlags`, so the status menu item can show
    /// the shortcut next to its title.
    public var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }
}

/// Seam over the system call that registers a global shortcut, so the enable/disable
/// logic is testable without taking over a real key combination.
protocol HotKeyRegistering: AnyObject {
    /// Returns false when the combination could not be registered (usually: another app owns it).
    func register(_ binding: HotKeyBinding, action: @escaping () -> Void) -> Bool
    func unregister()
}

/// Carbon `RegisterEventHotKey`: the one global-shortcut API that needs no Accessibility or
/// Input Monitoring permission, because the system delivers only the registered combination.
final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var action: (() -> Void)?

    /// 'DSNT'
    private static let signature: OSType = 0x4453_4E54
    private static let hotKeyIdentifier: UInt32 = 1

    func register(_ binding: HotKeyBinding, action: @escaping () -> Void) -> Bool {
        unregister()
        guard installHandlerIfNeeded() else { return false }
        self.action = action
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyIdentifier)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            self.action = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        action = nil
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard result == noErr,
                      id.signature == CarbonHotKeyRegistrar.signature,
                      id.id == CarbonHotKeyRegistrar.hotKeyIdentifier
                else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { registrar.action?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            handlerRef = nil
            return false
        }
        return true
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}

/// Keeps the global show-notch shortcut registered exactly while its Settings switch is on,
/// and reports whether registration worked so Settings can say so instead of failing silently.
@MainActor
public final class GlobalHotKeyController: ObservableObject {
    public enum Status: Equatable {
        case off
        case active
        /// The switch is on but the system refused the combination (another app owns it).
        case unavailable
    }

    @Published public private(set) var status: Status = .off

    public let binding: HotKeyBinding
    private let registrar: HotKeyRegistering
    private let onTrigger: () -> Void
    private var cancellable: AnyCancellable?

    public convenience init(onTrigger: @escaping () -> Void) {
        self.init(
            settings: .shared,
            binding: .default,
            registrar: CarbonHotKeyRegistrar(),
            onTrigger: onTrigger
        )
    }

    /// Internal injection point so tests can drive registration without touching the system.
    init(
        settings: SettingsStore,
        binding: HotKeyBinding,
        registrar: HotKeyRegistering,
        onTrigger: @escaping () -> Void
    ) {
        self.binding = binding
        self.registrar = registrar
        self.onTrigger = onTrigger
        cancellable = settings.$globalHotkeyEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.apply(enabled: enabled) }
    }

    /// Releases the key combination (app termination).
    public func stop() {
        cancellable = nil
        registrar.unregister()
        status = .off
    }

    private func apply(enabled: Bool) {
        guard enabled else {
            registrar.unregister()
            status = .off
            return
        }
        let registered = registrar.register(binding) { [weak self] in
            // Carbon's handler hops to the main queue before calling this.
            MainActor.assumeIsolated { self?.onTrigger() }
        }
        status = registered ? .active : .unavailable
    }
}
