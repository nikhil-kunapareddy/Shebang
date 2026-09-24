import Foundation
import ShebangCore

/// Starts the hotkey monitor, which throws until Accessibility is granted. When it can't start, polls once a second
/// and starts it as soon as the permission appears, so the user never has to relaunch.
@MainActor
final class HotkeyStarter {
    private let startMonitor: () throws -> Void
    private let isTrusted: () -> Bool
    private var timer: Timer?
    private var loggedFailure = false

    private(set) var isListening = false
    var onListeningChanged: ((Bool) -> Void)?
    var pollInterval: TimeInterval = 1

    init(start: @escaping () throws -> Void, isTrusted: @escaping () -> Bool) {
        self.startMonitor = start
        self.isTrusted = isTrusted
    }

    var isPolling: Bool { timer != nil }

    func begin() {
        guard !attempt() else { return }
        Log.app.notice("Hotkey is waiting for Accessibility access")
        schedulePolling()
    }

    /// Tries to start the monitor once; returns whether it is listening.
    @discardableResult
    func attempt() -> Bool {
        if isListening { return true }
        guard isTrusted() else { return false }
        do {
            try startMonitor()
        } catch {
            if !loggedFailure {
                loggedFailure = true
                Log.app.error("Hotkey monitor failed to start: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
        isListening = true
        stopPolling()
        Log.app.info("Hotkey listening (Control+Command)")
        onListeningChanged?(true)
        return true
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func schedulePolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.attempt() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
