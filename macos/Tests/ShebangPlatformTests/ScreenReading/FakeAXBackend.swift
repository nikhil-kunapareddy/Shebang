import ApplicationServices
import CoreGraphics
import Foundation
import ShebangCore
@testable import ShebangPlatform

/// In-memory AX tree. Handles are real `AXUIElement` objects (created for fake, out-of-range pids so they
/// compare by identity) but are never passed to the Accessibility API — no TCC permission is needed.
final class FakeAXBackend: AXBackend, @unchecked Sendable {
    final class Node {
        let handle: AXUIElement
        let pid: Int32
        var snapshot: AXNodeSnapshot
        var value: String?
        var actions: [String]
        var settable: Bool
        var readResult: AXReadResult?
        var transientTimeouts = 0
        var parent: AXUIElement?

        init(handle: AXUIElement, pid: Int32, snapshot: AXNodeSnapshot, value: String?, actions: [String], settable: Bool) {
            self.handle = handle
            self.pid = pid
            self.snapshot = snapshot
            self.value = value
            self.actions = actions
            self.settable = settable
        }
    }

    private let lock = NSLock()
    private var nodes: [AXUIElement: Node] = [:]
    private var apps: [Int32: AXUIElement] = [:]
    private var focusedWindows: [AXUIElement: AXUIElement] = [:]
    private var focusedElements: [AXUIElement: AXUIElement] = [:]
    private var nextHandleID: Int32 = 2_000_000_000

    var isTrusted = true
    var hitTestResult: AXUIElement?
    var failingActions: Set<String> = []
    var setValueSucceeds = true
    /// Simulates apps that accept an AXValue write but show something else (e.g. autocomplete, web inputs).
    var readBackOverride: String??
    /// Called when a focus request is made (lets tests move focus like a real app would).
    var onFocusRequest: ((AXUIElement) -> Void)?

    private(set) var valueReads: [AXUIElement] = []
    private(set) var snapshotReads = 0
    private(set) var performedActions: [(action: String, element: AXUIElement)] = []
    private(set) var setValues: [(value: String, element: AXUIElement)] = []
    private(set) var setBools: [(attribute: String, value: Bool, element: AXUIElement)] = []

    private func makeHandle() -> AXUIElement {
        lock.withLock {
            nextHandleID += 1
            return AXUIElementCreateApplication(nextHandleID)
        }
    }

    // MARK: Builders

    func app(pid: Int32) -> AXUIElement {
        if let existing = lock.withLock({ apps[pid] }) { return existing }
        let handle = makeHandle()
        lock.withLock {
            nodes[handle] = Node(handle: handle, pid: pid, snapshot: AXNodeSnapshot(role: "AXApplication"),
                                 value: nil, actions: [], settable: false)
            apps[pid] = handle
        }
        return handle
    }

    @discardableResult
    func add(
        _ role: String,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        placeholder: String? = nil,
        value: String? = nil,
        frame: CGRect? = CGRect(x: 10, y: 10, width: 80, height: 20),
        enabled: Bool = true,
        focused: Bool = false,
        actions: [String] = [],
        settable: Bool = false,
        to parent: AXUIElement
    ) -> AXUIElement {
        let handle = makeHandle()
        lock.withLock {
            let parentNode = nodes[parent]!
            let node = Node(
                handle: handle,
                pid: parentNode.pid,
                snapshot: AXNodeSnapshot(role: role, subrole: subrole, title: title, description: description,
                                         placeholder: placeholder, enabled: enabled, focused: focused, frame: frame),
                value: value, actions: actions, settable: settable)
            node.parent = parent
            nodes[handle] = node
            parentNode.snapshot.children.append(handle)
        }
        return handle
    }

    /// Adds a window under the app and makes it the focused window.
    @discardableResult
    func window(pid: Int32, title: String = "Main", frame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 800)) -> AXUIElement {
        let app = app(pid: pid)
        let window = add("AXWindow", title: title, frame: frame, to: app)
        lock.withLock { focusedWindows[app] = window }
        return window
    }

    func node(_ handle: AXUIElement) -> Node? {
        lock.withLock { nodes[handle] }
    }

    func setReadResult(_ result: AXReadResult, for handle: AXUIElement) {
        lock.withLock { nodes[handle]?.readResult = result }
    }

    /// The node answers `.timedOut` this many times before responding normally.
    func setTransientTimeouts(_ count: Int, for handle: AXUIElement) {
        lock.withLock { nodes[handle]?.transientTimeouts = count }
    }

    func setFocusedElement(_ element: AXUIElement?, pid: Int32) {
        let app = app(pid: pid)
        lock.withLock { focusedElements[app] = element }
    }

    // MARK: AXBackend

    func applicationElement(pid: Int32) -> AXUIElement { app(pid: pid) }

    func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        lock.withLock { focusedWindows[app] }
    }

    func windowRoot(of app: AXUIElement) -> AXUIElement? { focusedWindow(of: app) }

    func snapshot(of element: AXUIElement) -> AXReadResult {
        lock.withLock {
            snapshotReads += 1
            guard let node = nodes[element] else { return .unavailable }
            if node.transientTimeouts > 0 {
                node.transientTimeouts -= 1
                return .timedOut
            }
            if let override = node.readResult { return override }
            return .node(node.snapshot)
        }
    }

    func value(of element: AXUIElement) -> String? {
        lock.withLock {
            valueReads.append(element)
            if setValues.contains(where: { $0.element == element }), let override = readBackOverride { return override }
            return nodes[element]?.value
        }
    }

    func actionNames(of element: AXUIElement) -> [String] {
        lock.withLock { nodes[element]?.actions ?? [] }
    }

    func roleAndSubrole(of element: AXUIElement) -> (role: String, subrole: String?)? {
        lock.withLock { nodes[element].map { ($0.snapshot.role, $0.snapshot.subrole) } }
    }

    func frame(of element: AXUIElement) -> CGRect? {
        lock.withLock { nodes[element]?.snapshot.frame }
    }

    func isFocused(_ element: AXUIElement) -> Bool? {
        lock.withLock { nodes[element]?.snapshot.focused }
    }

    func processID(of element: AXUIElement) -> Int32? {
        lock.withLock { nodes[element]?.pid }
    }

    func focusedElement(of app: AXUIElement) -> AXUIElement? {
        lock.withLock { focusedElements[app] }
    }

    func parent(of element: AXUIElement) -> AXUIElement? {
        lock.withLock { nodes[element]?.parent }
    }

    func element(at point: CGPoint, in app: AXUIElement) -> AXUIElement? { hitTestResult }

    func isValueSettable(_ element: AXUIElement) -> Bool {
        lock.withLock { nodes[element]?.settable ?? false }
    }

    func performAction(_ action: String, on element: AXUIElement) -> Bool {
        lock.withLock {
            performedActions.append((action, element))
            return !failingActions.contains(action) && nodes[element] != nil
        }
    }

    func setValue(_ value: String, on element: AXUIElement) -> Bool {
        lock.withLock {
            setValues.append((value, element))
            guard setValueSucceeds, let node = nodes[element] else { return false }
            node.value = value
            return true
        }
    }

    func setBool(_ attribute: String, _ value: Bool, on element: AXUIElement) -> Bool {
        lock.withLock { setBools.append((attribute, value, element)) }
        if attribute == kAXFocusedAttribute, value { onFocusRequest?(element) }
        return lock.withLock { nodes[element] != nil }
    }
}

/// Clock that never waits but records requested sleeps.
final class InstantClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [TimeInterval] = []
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }
    var now: Date { Date(timeIntervalSince1970: 1_000_000) }

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { _sleeps.append(seconds) }
    }
}

final class FakeOCRService: OCRService, @unchecked Sendable {
    var result: Result<[AccessibilityElement], Error> = .success([])
    private(set) var calls = 0

    func recognizeText(in target: AppTarget) async throws -> [AccessibilityElement] {
        calls += 1
        return try result.get()
    }
}

struct FakeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LiveUI {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SHEBANG_LIVE_UI_TESTS"] == "1" }
}
