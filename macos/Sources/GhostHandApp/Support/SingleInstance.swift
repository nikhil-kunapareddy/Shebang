import AppKit
import GhostHandCore

/// One GhostHand per user session (the Windows build used a named mutex).
enum SingleInstance {
    static let bundleIdentifier = "com.ghosthand.mac"
    /// Posted by a second copy so the running one shows its Status & Permissions window.
    static let showStatusNotification = Notification.Name("com.ghosthand.mac.showStatus")

    struct Instance: Equatable {
        var pid: pid_t
        var launchDate: Date?
    }

    /// The earliest-launched other instance (ties broken by lower PID), if it predates `current`. Two copies launched
    /// together agree on the survivor instead of both exiting.
    static func instanceToDeferTo(current: Instance, others: [Instance]) -> Instance? {
        others
            .filter { $0.pid != current.pid && launchedBefore($0, current) }
            .min(by: launchedBefore)
    }

    static func launchedBefore(_ lhs: Instance, _ rhs: Instance) -> Bool {
        if let left = lhs.launchDate, let right = rhs.launchDate, left != right {
            return left < right
        }
        return lhs.pid < rhs.pid
    }

    /// When another copy is already running, activates it, asks it to show its status window, and returns true
    /// (the caller should exit).
    @MainActor
    static func handOffToRunningInstance() -> Bool {
        let current = NSRunningApplication.current
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        let others = running.map { Instance(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        guard let survivor = instanceToDeferTo(
                current: Instance(pid: current.processIdentifier, launchDate: current.launchDate), others: others),
              let app = running.first(where: { $0.processIdentifier == survivor.pid })
        else { return false }

        Log.app.info("GhostHand is already running (PID \(survivor.pid)); activating it and exiting")
        app.activate(options: [])
        DistributedNotificationCenter.default().postNotificationName(
            showStatusNotification, object: nil, userInfo: nil, deliverImmediately: true)
        return true
    }
}
