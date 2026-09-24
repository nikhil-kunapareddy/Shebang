import CoreGraphics
import Foundation
import GhostHandCore

public enum HotkeyError: Error, LocalizedError, Equatable {
    case accessibilityNotGranted
    case eventTapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "GhostHand needs Accessibility access to listen for the Control+Command hotkey. "
                + "Enable it in System Settings → Privacy & Security → Accessibility, then relaunch GhostHand."
        case .eventTapCreationFailed:
            return "Could not install the keyboard event tap for the Control+Command hotkey. "
                + "Check System Settings → Privacy & Security → Accessibility."
        }
    }
}

/// Listens for the Control+Command chord (and Esc while a run is active) with a CGEventTap on a
/// dedicated run-loop thread. Events are passed through unmodified.
public final class GlobalHotkeyMonitor: HotkeyService {
    public var onHotkeyPressed: (() -> Void)?
    public var onKillSwitch: (() -> Void)?

    /// Set while an agent run is in progress so the chord and Esc act as the kill switch.
    public var isRunActive: Bool {
        get { router.isRunActive }
        set { router.isRunActive = newValue }
    }

    let router = HotkeyEventRouter()
    private let isTrusted: () -> Bool
    private let lock = NSLock()
    private var eventTap: HotkeyEventTap?

    public convenience init() {
        self.init(isTrusted: { Permissions.isAccessibilityTrusted })
    }

    init(isTrusted: @escaping () -> Bool) {
        self.isTrusted = isTrusted
        router.onTrigger = { [weak self] in
            DispatchQueue.main.async { self?.onHotkeyPressed?() }
        }
        router.onCancel = { [weak self] in
            DispatchQueue.main.async { self?.onKillSwitch?() }
        }
    }

    deinit {
        eventTap?.stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard eventTap == nil else { return }

        guard isTrusted() else {
            Log.hotkey.error("Accessibility not granted; hotkey monitor not started")
            throw HotkeyError.accessibilityNotGranted
        }

        let tap = HotkeyEventTap(router: router)
        try tap.start()
        router.reset()
        eventTap = tap
        Log.hotkey.info("Hotkey monitor started (Control+Command)")
    }

    public func stop() {
        lock.lock()
        let tap = eventTap
        eventTap = nil
        lock.unlock()

        guard let tap else { return }
        tap.stop()
        Log.hotkey.info("Hotkey monitor stopped")
    }

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventTap != nil
    }
}

/// Serializes access to the chord machine between the tap thread and the run-state setter.
final class HotkeyEventRouter: @unchecked Sendable {
    private let lock = NSLock()
    private let machine = ChordStateMachine()
    private var runActive = false

    var onTrigger: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        machine.onTrigger = { [weak self] in self?.onTrigger?() }
        machine.onCancel = { [weak self] in self?.onCancel?() }
    }

    var isRunActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return runActive
        }
        set {
            lock.lock()
            runActive = newValue
            lock.unlock()
        }
    }

    var state: ChordStateMachine.State {
        lock.lock()
        defer { lock.unlock() }
        return machine.currentState
    }

    /// Callbacks run synchronously on the calling thread; the monitor hops them to main.
    func handle(_ event: RawKeyEvent) {
        lock.lock()
        defer { lock.unlock() }
        machine.isRunActive = runActive
        machine.processKeyEvent(event)
    }

    func reset() {
        lock.lock()
        machine.reset()
        lock.unlock()
    }
}

/// Owns the mach port and the thread whose run loop services it.
private final class HotkeyEventTap: @unchecked Sendable {
    private let router: HotkeyEventRouter
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopped = false
    private let exited = DispatchSemaphore(value: 0)

    init(router: HotkeyEventRouter) {
        self.router = router
    }

    func start() throws {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // `self` stays alive while the thread runs because the thread closure retains it.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.hotkey.error("CGEvent.tapCreate failed")
            throw HotkeyError.eventTapCreationFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw HotkeyError.eventTapCreationFailed
        }
        self.port = port

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.lock()
            runLoop = loop
            lock.unlock()
            ready.signal()

            // Poll the stop flag so a CFRunLoopStop issued before the loop starts can't be lost.
            while !isStopped {
                _ = CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }

            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(port)
            exited.signal()
        }
        thread.name = "GhostHand.HotkeyEventTap"
        thread.qualityOfService = .userInteractive
        thread.start()

        if ready.wait(timeout: .now() + 3) == .timedOut {
            Log.hotkey.error("Hotkey tap thread did not start in time")
            stop()
            throw HotkeyError.eventTapCreationFailed
        }
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let loop = runLoop
        let port = self.port
        lock.unlock()
        guard !alreadyStopped else { return }

        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
            _ = exited.wait(timeout: .now() + 2)
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Key-ups may have been missed while disabled; start from a clean slate.
            router.reset()
            lock.lock()
            let port = stopped ? nil : self.port
            lock.unlock()
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
                Log.hotkey.notice("Event tap was disabled (\(type.rawValue)); re-enabled")
            }
        case .keyDown, .keyUp:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            router.handle(RawKeyEvent(
                keyCode: keyCode,
                isKeyUp: type == .keyUp,
                isInjected: Self.isSelfInjected(event),
                timestampMs: event.timestamp / 1_000_000
            ))
        case .flagsChanged:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if let raw = RawKeyEvent.fromFlagsChanged(
                keyCode: keyCode,
                flags: event.flags.rawValue,
                isInjected: Self.isSelfInjected(event),
                timestampMs: event.timestamp / 1_000_000
            ) {
                router.handle(raw)
            }
        default:
            break
        }
    }

    /// Events synthesized by this process (the action executor) must not trip the chord or kill switch.
    private static func isSelfInjected(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<HotkeyEventTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
