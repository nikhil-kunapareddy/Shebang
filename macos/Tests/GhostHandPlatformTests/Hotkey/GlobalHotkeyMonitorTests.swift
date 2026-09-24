import Foundation
import Testing
@testable import GhostHandPlatform

@Suite struct GlobalHotkeyMonitorTests {
    private func sendChord(to router: HotkeyEventRouter) {
        router.handle(.keyDown(RawKeyEvent.vkControl))
        router.handle(.keyDown(RawKeyEvent.vkCommand))
        router.handle(.keyUp(RawKeyEvent.vkCommand))
        router.handle(.keyUp(RawKeyEvent.vkControl))
    }

    @Test func startThrowsDescriptiveErrorWithoutAccessibility() {
        let monitor = GlobalHotkeyMonitor(isTrusted: { false })
        #expect(throws: HotkeyError.accessibilityNotGranted) { try monitor.start() }
        #expect(!monitor.isStarted)
        #expect(HotkeyError.accessibilityNotGranted.localizedDescription.contains("Accessibility"))
        monitor.stop() // no-op, must not crash
    }

    @Test func isRunActiveIsThreadSafe() {
        let monitor = GlobalHotkeyMonitor(isTrusted: { false })
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            monitor.isRunActive = index.isMultiple(of: 2)
            _ = monitor.isRunActive
        }
        monitor.isRunActive = true
        #expect(monitor.isRunActive)
        #expect(monitor.router.isRunActive)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func chordDeliversHotkeyOnMainThread() async {
        let monitor = GlobalHotkeyMonitor(isTrusted: { false })
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            monitor.onHotkeyPressed = {
                #expect(Thread.isMainThread)
                continuation.resume()
            }
            monitor.onKillSwitch = { Issue.record("Kill switch should not fire when idle") }
            let router = monitor.router
            DispatchQueue.global().async { sendChord(to: router) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func escapeWhileRunningDeliversKillSwitchOnMainThread() async {
        let monitor = GlobalHotkeyMonitor(isTrusted: { false })
        monitor.isRunActive = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            monitor.onKillSwitch = {
                #expect(Thread.isMainThread)
                continuation.resume()
            }
            monitor.onHotkeyPressed = { Issue.record("Hotkey should not fire while a run is active") }
            let router = monitor.router
            DispatchQueue.global().async {
                router.handle(.keyDown(RawKeyEvent.vkEscape))
                router.handle(.keyUp(RawKeyEvent.vkEscape))
            }
        }
    }

    /// Installs a real event tap when Accessibility is granted; run with `GHOSTHAND_LIVE_TESTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GHOSTHAND_LIVE_TESTS"] == "1"))
    func liveStartAndStop() throws {
        let monitor = GlobalHotkeyMonitor()
        guard Permissions.isAccessibilityTrusted else {
            #expect(throws: HotkeyError.accessibilityNotGranted) { try monitor.start() }
            return
        }
        try monitor.start()
        try monitor.start() // idempotent
        #expect(monitor.isStarted)
        monitor.stop()
        #expect(!monitor.isStarted)
        try monitor.start() // restartable
        monitor.stop()
    }

    @Test func routerResetDropsHeldModifiers() {
        let router = HotkeyEventRouter()
        router.handle(.keyDown(RawKeyEvent.vkControl))
        router.handle(.keyDown(RawKeyEvent.vkCommand))
        #expect(router.state.chordArmed)
        router.reset()
        #expect(router.state == .init(controlDown: false, commandDown: false, chordArmed: false, interrupted: false))
    }
}
