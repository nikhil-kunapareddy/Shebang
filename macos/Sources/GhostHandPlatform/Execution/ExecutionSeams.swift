import AppKit
import CoreGraphics
import Foundation
import GhostHandCore

/// Synthetic input used by `MacActionExecutor`; faked in tests so they never move the real mouse.
protocol InputSink: AnyObject {
    func click(at point: CGPoint) -> Bool
    /// Stops early, returning false, as soon as `shouldContinue` returns false.
    func typeText(_ text: String, shouldContinue: () -> Bool) -> Bool
    /// Key code that types `character` in the user's keyboard layout, for shortcuts like ⌘A.
    func keyCode(for character: Character) -> CGKeyCode
    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool
    func scroll(lines: Int, at point: CGPoint?) -> Bool
    func pressMediaPlayPause() -> Bool
}

final class SystemInputSink: InputSink {
    func click(at point: CGPoint) -> Bool { InputSimulator.click(at: point) }
    func typeText(_ text: String, shouldContinue: () -> Bool) -> Bool {
        InputSimulator.typeText(text, shouldContinue: shouldContinue)
    }
    func keyCode(for character: Character) -> CGKeyCode { InputSimulator.keyCode(for: character) }
    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool { InputSimulator.pressKey(keyCode, flags: flags) }
    func scroll(lines: Int, at point: CGPoint?) -> Bool { InputSimulator.scroll(lines: lines, at: point) }
    func pressMediaPlayPause() -> Bool { InputSimulator.pressMediaPlayPause() }
}

/// Process/focus queries and activation used by `MacActionExecutor`.
protocol WorkspaceControl: AnyObject {
    var ownProcessID: Int32 { get }
    func frontmostProcessID() -> Int32?
    func isRunning(_ pid: Int32) -> Bool
    func activate(_ target: AppTarget) -> Bool
    func describeProcess(_ pid: Int32) -> AppTarget?
}

final class SystemWorkspaceControl: WorkspaceControl {
    private let tracker = FrontmostWindowTracker()

    var ownProcessID: Int32 { getpid() }

    func frontmostProcessID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func isRunning(_ pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    func activate(_ target: AppTarget) -> Bool {
        tracker.activate(target)
    }

    func describeProcess(_ pid: Int32) -> AppTarget? {
        tracker.target(forProcessID: pid)
    }
}
