import CoreGraphics
import Foundation
import ShebangCore
@testable import ShebangPlatform

/// Records synthetic input instead of posting it: tests never move the real mouse or type.
final class FakeInputSink: InputSink, @unchecked Sendable {
    enum Event: Equatable {
        case click(CGPoint)
        case type(String)
        case key(CGKeyCode, CGEventFlags)
        case scroll(Int, CGPoint?)
        case mediaPlayPause
    }

    private(set) var events: [Event] = []
    var succeeds = true
    /// Runs before each typed character, e.g. to switch the frontmost app mid-string.
    var beforeCharacter: ((Int) -> Void)?
    /// Layout lookups answer with US positions unless overridden (AZERTY puts "a" at 0x0C).
    var layout: [Character: CGKeyCode] = ["a": 0x00, "k": 0x28]

    func click(at point: CGPoint) -> Bool { events.append(.click(point)); return succeeds }

    /// Records the characters typed before `shouldContinue` stopped the string.
    func typeText(_ text: String, shouldContinue: () -> Bool) -> Bool {
        var typed = ""
        for (index, character) in text.enumerated() {
            beforeCharacter?(index)
            guard shouldContinue() else {
                if !typed.isEmpty { events.append(.type(typed)) }
                return false
            }
            typed.append(character)
        }
        events.append(.type(typed))
        return succeeds
    }

    func keyCode(for character: Character) -> CGKeyCode { layout[character] ?? 0x00 }
    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool { events.append(.key(keyCode, flags)); return succeeds }
    func scroll(lines: Int, at point: CGPoint?) -> Bool { events.append(.scroll(lines, point)); return succeeds }
    func pressMediaPlayPause() -> Bool { events.append(.mediaPlayPause); return succeeds }

    var typedText: [String] {
        events.compactMap { if case .type(let text) = $0 { return text } else { return nil } }
    }
}

final class FakeWorkspace: WorkspaceControl, @unchecked Sendable {
    var ownProcessID: Int32 = 1
    /// Successive answers to `frontmostProcessID()`; the last one sticks.
    var frontmostSequence: [Int32?]
    var running: Set<Int32>
    var activationBringsToFront = true
    var described: [Int32: AppTarget] = [:]
    private(set) var activations: [AppTarget] = []
    private(set) var frontmostQueries = 0

    init(frontmost: Int32?, running: Set<Int32>) {
        self.frontmostSequence = [frontmost]
        self.running = running
    }

    var frontmost: Int32? {
        get { frontmostSequence.last ?? nil }
        set { frontmostSequence = [newValue] }
    }

    func frontmostProcessID() -> Int32? {
        frontmostQueries += 1
        return frontmostSequence.count > 1 ? frontmostSequence.removeFirst() : frontmostSequence.first ?? nil
    }

    func isRunning(_ pid: Int32) -> Bool { running.contains(pid) }

    func activate(_ target: AppTarget) -> Bool {
        activations.append(target)
        if activationBringsToFront { frontmost = target.processId }
        return activationBringsToFront
    }

    func describeProcess(_ pid: Int32) -> AppTarget? { described[pid] }
}

final class FakeAppLauncher: AppLauncher, @unchecked Sendable {
    var appResult: AppTarget?
    var urlResult: AppTarget?
    var error: Error?
    private(set) var launchedApps: [(name: String, command: String?)] = []
    private(set) var launchedURLs: [URL] = []

    func extractAppLaunch(from goal: String) -> (appName: String, launchCommand: String)? { nil }
    func extractURLLaunch(from goal: String) -> URL? { nil }

    func launchApp(named appName: String, launchCommand: String?) async throws -> AppTarget? {
        launchedApps.append((appName, launchCommand))
        if let error { throw error }
        return appResult
    }

    func launchURL(_ url: URL) async throws -> AppTarget? {
        launchedURLs.append(url)
        if let error { throw error }
        return urlResult
    }
}
