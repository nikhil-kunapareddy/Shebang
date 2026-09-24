import AppKit
import ApplicationServices
import Foundation
import ShebangCore

/// Captures the frontmost app/window as an `AppTarget` and tracks focus changes during a run.
public final class FrontmostWindowTracker: WindowTracker, @unchecked Sendable {
    /// System surfaces that are never a sensible automation target.
    static let ignoredBundleIdentifiers: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui", "com.apple.dock", "com.apple.WindowManager",
    ]

    /// What the tracker needs from `NSRunningApplication` (a seam: CLI test runners have no running-app record).
    struct RunningAppInfo: Equatable {
        var name: String
        var bundleIdentifier: String
        var executablePath: String
    }

    private let ax: AXBackend
    private let appInfo: (Int32) -> RunningAppInfo?
    private let windowInfo: () -> [[String: Any]]

    public convenience init() {
        self.init(ax: LiveAXBackend.shared)
    }

    init(
        ax: AXBackend,
        appInfo: @escaping (Int32) -> RunningAppInfo? = FrontmostWindowTracker.runningAppInfo,
        windowInfo: @escaping () -> [[String: Any]] = WindowList.onScreenWindowInfo
    ) {
        self.ax = ax
        self.appInfo = appInfo
        self.windowInfo = windowInfo
    }

    static func runningAppInfo(_ pid: Int32) -> RunningAppInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return RunningAppInfo(name: app.localizedName ?? "Unknown", bundleIdentifier: app.bundleIdentifier ?? "",
                              executablePath: app.executableURL?.path ?? "")
    }

    /// The frontmost app, or — when that is Shebang itself — the owner of the frontmost normal window
    /// underneath it.
    public func captureFrontmost() -> AppTarget? {
        let ownPID = getpid()
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ownPID,
           !Self.isIgnored(app.bundleIdentifier) {
            return target(forProcessID: app.processIdentifier)
        }
        for window in WindowList.candidates(from: windowInfo()) where window.ownerPID != ownPID {
            guard let app = NSRunningApplication(processIdentifier: window.ownerPID),
                  app.activationPolicy == .regular, !Self.isIgnored(app.bundleIdentifier) else { continue }
            return target(forProcessID: window.ownerPID)
        }
        Log.screen.info("captureFrontmost: no eligible frontmost application")
        return nil
    }

    /// Describes a running app: title/bounds from its AX focused window (when Accessibility is granted),
    /// window number from the matching CGWindowList entry.
    public func target(forProcessID pid: Int32) -> AppTarget? {
        guard let app = appInfo(pid) else { return nil }
        var title = ""
        var bounds = CGRect.zero
        if ax.isTrusted, let window = ax.focusedWindow(of: ax.applicationElement(pid: pid)),
           case .node(let snapshot) = ax.snapshot(of: window) {
            title = snapshot.title ?? ""
            bounds = snapshot.frame ?? .zero
        }
        let windows = WindowList.candidates(from: windowInfo(), pid: pid)
        let selected = WindowList.select(windows, focusedFrame: bounds.isEmpty ? nil : bounds)
        if title.isEmpty { title = selected?.title ?? "" }
        if bounds.isEmpty { bounds = selected?.frame ?? .zero }
        return AppTarget(
            processId: pid,
            processName: app.name,
            bundleIdentifier: app.bundleIdentifier,
            executablePath: app.executablePath,
            windowTitle: title,
            windowNumber: Int(selected?.id ?? 0),
            windowBounds: bounds
        )
    }

    /// Brings the target app forward and raises its window. Uses AX (`AXFrontmost` + `AXRaise`) as well as
    /// `NSRunningApplication.activate`, because cooperative activation may ignore requests from a background agent.
    @discardableResult
    public func activate(_ target: AppTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.processId), !app.isTerminated else {
            Log.input.warning("activate: \(target.processName, privacy: .public) (PID \(target.processId)) is not running")
            return false
        }
        if app.isHidden { app.unhide() }
        var activated = app.activate(options: [])
        if ax.isTrusted {
            let appElement = ax.applicationElement(pid: target.processId)
            activated = ax.setBool(kAXFrontmostAttribute, true, on: appElement) || activated
            if let window = matchingWindow(for: target, in: appElement) {
                ax.performAction(kAXRaiseAction, on: window)
            }
        }
        return activated
    }

    public func activeTarget(current: AppTarget) -> AppTarget? {
        Self.resolveActiveTarget(current: current, frontmost: captureFrontmost())
    }

    // MARK: - Pure policy

    /// Finder with no real window focused, i.e. the desktop itself (also true when no app was captured).
    static func isFinderDesktop(_ target: AppTarget?) -> Bool {
        guard let target else { return true }
        let isFinder = target.bundleIdentifier == "com.apple.finder"
            || (target.bundleIdentifier.isEmpty && target.processName.caseInsensitiveCompare("Finder") == .orderedSame)
        guard isFinder else { return false }
        let title = target.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title.caseInsensitiveCompare("Desktop") == .orderedSame
    }

    /// Follows focus from the Finder desktop into an app, or to another window of the same app; otherwise keeps
    /// the current target (a different app taking focus is not auto-followed).
    static func resolveActiveTarget(current: AppTarget, frontmost: AppTarget?) -> AppTarget {
        guard let frontmost else { return current }
        if isFinderDesktop(current) && !isFinderDesktop(frontmost) { return frontmost }
        if frontmost.processId == current.processId && isDifferentWindow(frontmost, current) { return frontmost }
        return current
    }

    static func isDifferentWindow(_ a: AppTarget, _ b: AppTarget) -> Bool {
        if a.windowNumber != 0 && b.windowNumber != 0 { return a.windowNumber != b.windowNumber }
        return a.windowTitle != b.windowTitle || !WindowList.framesMatch(a.windowBounds, b.windowBounds)
    }

    static func isIgnored(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return ignoredBundleIdentifiers.contains(bundleIdentifier)
    }

    private func matchingWindow(for target: AppTarget, in appElement: AXUIElement) -> AXUIElement? {
        guard let focused = ax.focusedWindow(of: appElement) else { return nil }
        guard !target.windowTitle.isEmpty || !target.windowBounds.isEmpty else { return focused }
        // Raise only the recorded window, never an arbitrary one.
        if case .node(let snapshot) = ax.snapshot(of: focused),
           (snapshot.title ?? "") == target.windowTitle
            || snapshot.frame.map({ WindowList.framesMatch($0, target.windowBounds) }) == true {
            return focused
        }
        return nil
    }
}
