import Carbon.HIToolbox
import Foundation

enum HotKeyOutcome: Equatable, Sendable {
    case talkPressed
    case talkReleased
    case stopChord
    case escPressed
}

struct PressTracker: Sendable {
    static let staleAfter: TimeInterval = 35
    private var pressStartTime: TimeInterval?

    mutating func press(at time: TimeInterval) -> Bool {
        if let start = pressStartTime {
            if time - start < Self.staleAfter {
                return false
            }
        }
        pressStartTime = time
        return true
    }

    mutating func release(at time: TimeInterval) -> Double? {
        guard let start = pressStartTime else { return nil }
        pressStartTime = nil
        return max(0, time - start)
    }

    mutating func event(for outcome: HotKeyOutcome, at time: TimeInterval) -> PushToTalkEvent? {
        switch outcome {
        case .talkPressed:
            return press(at: time) ? .pressed : nil
        case .talkReleased:
            guard let held = release(at: time) else { return nil }
            return .released(heldSeconds: held)
        case .stopChord:
            return .stopKey
        case .escPressed:
            return .cancelKey
        }
    }
}

final class CarbonHotKeyBox: @unchecked Sendable {
    static let signature: OSType = 0x4453_5643 // 'DSVC'

    private let lock = NSLock()
    private let uptimeClosure: @Sendable () -> TimeInterval
    private var sinkClosure: (@Sendable (HotKeyOutcome, TimeInterval) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    init(uptime: @escaping @Sendable () -> TimeInterval) {
        self.uptimeClosure = uptime
    }

    func setSink(_ sink: @escaping @Sendable (HotKeyOutcome, TimeInterval) -> Void) {
        lock.lock()
        self.sinkClosure = sink
        lock.unlock()
    }

    func readUptime() -> TimeInterval {
        uptimeClosure()
    }

    func readSink() -> (@Sendable (HotKeyOutcome, TimeInterval) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return sinkClosure
    }

    static func isOwn(signature: OSType, id: UInt32) -> Bool {
        signature == Self.signature && (id == 1 || id == 2 || id == 3)
    }

    static func outcome(signature: OSType, id: UInt32, isRelease: Bool) -> HotKeyOutcome? {
        guard isOwn(signature: signature, id: id) else { return nil }
        switch id {
        case 1:
            return isRelease ? .talkReleased : .talkPressed
        case 2:
            return isRelease ? nil : .stopChord
        case 3:
            return isRelease ? nil : .escPressed
        default:
            return nil
        }
    }

    static let callback: EventHandlerUPP = { _, event, userData in
        guard let event = event, let userData = userData else {
            return OSStatus(eventNotHandledErr)
        }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return OSStatus(eventNotHandledErr) }
        guard isOwn(signature: hotKeyID.signature, id: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

        let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
        if let outcome = outcome(signature: hotKeyID.signature, id: hotKeyID.id, isRelease: isRelease) {
            let box = Unmanaged<CarbonHotKeyBox>.fromOpaque(userData).takeUnretainedValue()
            let time = box.readUptime()
            if let sink = box.readSink() {
                DispatchQueue.main.async {
                    sink(outcome, time)
                }
            }
        }
        return noErr
    }

    func installHandler() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if handlerRef != nil { return true }

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let target = GetApplicationEventTarget()
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(target, Self.callback, 2, &specs, userData, &handlerRef)
        return status == noErr
    }

    func register(binding: HotKeyBinding, id: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = hotKeyRefs[id] {
            UnregisterEventHotKey(existing)
            hotKeyRefs.removeValue(forKey: id)
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref = ref {
            hotKeyRefs[id] = ref
            return true
        }
        return false
    }

    func unregister(id: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    func teardown() {
        lock.lock()
        defer { lock.unlock() }
        sinkClosure = nil
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = handlerRef {
            RemoveEventHandler(handler)
            handlerRef = nil
        }
    }
}

@MainActor
final class CarbonPushToTalk: PushToTalkSource {
    let events: AsyncStream<PushToTalkEvent>
    private let continuation: AsyncStream<PushToTalkEvent>.Continuation
    private let box: CarbonHotKeyBox
    private let choice: VoiceHotkeyChoice

    private var tracker = PressTracker()
    private var isStarted = false
    private var isStopped = false
    private var isCancelArmed = false

    init(
        choice: VoiceHotkeyChoice,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.choice = choice
        self.box = CarbonHotKeyBox(uptime: uptime)
        let (stream, continuation) = AsyncStream<PushToTalkEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        box.teardown()
    }

    func start() -> PushToTalkStatus {
        if isStopped {
            return .unavailable
        }
        if isStarted {
            return .active
        }

        box.setSink { [weak self] outcome, time in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if let event = self.tracker.event(for: outcome, at: time) {
                    self.continuation.yield(event)
                }
            }
        }

        guard box.installHandler() else {
            box.teardown()
            return .unavailable
        }

        let talkBinding = VoiceHotkeyMap.binding(for: choice)
        let stopBinding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_Period),
            carbonModifiers: UInt32(cmdKey | optionKey),
            keyLabel: "."
        )

        let talkRegistered = box.register(binding: talkBinding, id: 1)
        let stopRegistered = box.register(binding: stopBinding, id: 2)

        guard talkRegistered && stopRegistered else {
            box.unregister(id: 1)
            box.unregister(id: 2)
            box.teardown()
            return .unavailable
        }

        isStarted = true

        if isCancelArmed {
            let escBinding = HotKeyBinding(
                keyCode: UInt32(kVK_Escape),
                carbonModifiers: 0,
                keyLabel: "Esc"
            )
            _ = box.register(binding: escBinding, id: 3)
        }

        return .active
    }

    func stop() {
        if isStopped { return }
        isStopped = true
        isStarted = false
        continuation.finish()
        box.teardown()
    }

    func setCancelKeyArmed(_ armed: Bool) {
        if isStopped {
            return
        }
        if !isStarted {
            isCancelArmed = armed
            return
        }
        if isCancelArmed == armed {
            return
        }
        isCancelArmed = armed
        if armed {
            let escBinding = HotKeyBinding(
                keyCode: UInt32(kVK_Escape),
                carbonModifiers: 0,
                keyLabel: "Esc"
            )
            _ = box.register(binding: escBinding, id: 3)
        } else {
            box.unregister(id: 3)
        }
    }
}
