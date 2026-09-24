import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore

/// Executes agent decisions against the target app (port of the Windows `ActionExecutor`).
/// Prefers Accessibility actions (AXPress, AXFocused + AXValue) and falls back to CGEvent input.
/// Before any input it re-activates the target when GhostHand itself holds focus, and aborts if the
/// user has switched to a different app.
public final class MacActionExecutor: ActionExecutor, @unchecked Sendable {
    public let dryRun: Bool

    private let appLauncher: AppLauncher?
    private let registry: AXElementRegistry
    private let ax: AXBackend
    private let input: InputSink
    private let workspace: WorkspaceControl
    private let clock: Clock
    private let lock = NSLock()
    private var currentTarget: AppTarget

    /// Lines per ScrollUp/ScrollDown step.
    var scrollLines = 5
    var focusAttempts = 11
    var focusInterval: TimeInterval = 0.1

    public var target: AppTarget {
        lock.withLock { currentTarget }
    }

    public convenience init(
        target: AppTarget,
        dryRun: Bool,
        appLauncher: AppLauncher? = nil,
        registry: AXElementRegistry = .shared
    ) {
        self.init(target: target, dryRun: dryRun, appLauncher: appLauncher, registry: registry,
                  ax: LiveAXBackend.shared, input: SystemInputSink(), workspace: SystemWorkspaceControl(),
                  clock: SystemClock())
    }

    init(
        target: AppTarget,
        dryRun: Bool,
        appLauncher: AppLauncher?,
        registry: AXElementRegistry,
        ax: AXBackend,
        input: InputSink,
        workspace: WorkspaceControl,
        clock: Clock
    ) {
        self.currentTarget = target
        self.dryRun = dryRun
        self.appLauncher = appLauncher
        self.registry = registry
        self.ax = ax
        self.input = input
        self.workspace = workspace
        self.clock = clock
    }

    public func retarget(_ target: AppTarget) {
        lock.withLock { currentTarget = target }
        Log.input.info("Executor retargeted to \(target.processName, privacy: .public) (PID \(target.processId))")
    }

    public func execute(_ decision: AgentDecision, targetElement: AccessibilityElement?) async throws -> ActionResult {
        try Task.checkCancellation()
        let started = clock.now
        var result = try await perform(decision, targetElement: targetElement)
        result.duration = max(0, clock.now.timeIntervalSince(started))
        return result
    }

    // MARK: - Dispatch

    private func perform(_ decision: AgentDecision, targetElement: AccessibilityElement?) async throws -> ActionResult {
        switch decision.operation {
        case .done:
            return .succeeded(message: "Task completed")
        case .askUser:
            return .succeeded(message: "User consultation requested")
        case .wait:
            try await clock.sleep(seconds: 1)
            return .succeeded(message: "Waited 1 second")
        default:
            break
        }

        let targetName = decision.targetLabel ?? decision.targetId ?? ""
        if dryRun {
            let value = Self.loggableText(decision.textValue ?? "", secure: Self.isSecure(targetElement))
            Log.input.info("""
                [DRY RUN] Would execute \(decision.operation.rawValue, privacy: .public) on \
                '\(targetName, privacy: .private)' with value '\(value, privacy: .private)'
                """)
            try await clock.sleep(seconds: 0.15)
            return .succeeded(message: "[DRY RUN] Simulated \(decision.operation.rawValue) on '\(targetName)'")
        }

        do {
            switch decision.operation {
            case .openApp: return try await openApp(decision)
            case .openUrl: return try await openURL(decision)
            case .blocked: return .failed("Blocked: \(decision.reason ?? "the next step cannot be performed").")
            default: break
            }

            if let failure = try await prepareForInput() { return failure }

            switch decision.operation {
            case .click, .clickText:
                return try await click(decision, element: targetElement)
            case .typeText:
                return try await typeText(decision, element: targetElement,
                                          submit: TextEntryHeuristics.isSearchOrAddressBar(targetElement))
            case .typeAndEnter:
                return try await typeText(decision, element: targetElement, submit: true)
            case .pressReturn:
                return pressKey(InputSimulator.KeyCode.returnKey, name: "Enter")
            case .pressTab:
                return pressKey(InputSimulator.KeyCode.tab, name: "Tab")
            case .pressEscape:
                return pressKey(InputSimulator.KeyCode.escape, name: "Escape")
            case .pressSpace:
                return pressKey(InputSimulator.KeyCode.space, name: "Space")
            case .pressMediaPlay:
                guard input.pressMediaPlayPause() else { return Self.inputFailure("media key") }
                return .succeeded(message: "Pressed Media Play/Pause key")
            case .scrollDown:
                return scroll(lines: -scrollLines, element: targetElement, direction: "down")
            case .scrollUp:
                return scroll(lines: scrollLines, element: targetElement, direction: "up")
            case .done, .askUser, .wait, .openApp, .openUrl, .blocked:
                return .failed("Unsupported operation '\(decision.operation.rawValue)'")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ExecutionFailure {
            Log.input.warning("\(decision.operation.rawValue, privacy: .public) aborted: \(failure.message, privacy: .public)")
            return .failed(failure.message)
        } catch {
            Log.input.error("""
                Failed to execute \(decision.operation.rawValue, privacy: .public) on \
                \(decision.targetId ?? "-", privacy: .public): \(error.localizedDescription, privacy: .public)
                """)
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Focus safety

    /// Verifies permission and that the target is still frontmost. When GhostHand itself (or nothing) holds
    /// focus the target is re-activated; a different app in front means the user switched away mid-run.
    private func prepareForInput() async throws -> ActionResult? {
        let target = self.target
        guard ax.isTrusted else { return .failed(Self.accessibilityRequiredMessage) }
        guard workspace.isRunning(target.processId) else {
            return .failed("Target application '\(target.processName)' (PID \(target.processId)) is no longer running.")
        }

        var frontmost = workspace.frontmostProcessID()
        if frontmost != target.processId, frontmost == nil || frontmost == workspace.ownProcessID {
            _ = workspace.activate(target)
            try await clock.sleep(seconds: 0.06)
            frontmost = workspace.frontmostProcessID()
        }
        if frontmost == target.processId { return nil }

        let found = frontmost ?? 0
        // Port of the Windows desktop-shell migration: starting from the Finder desktop, follow the app that took focus.
        if FrontmostWindowTracker.isDesktopOrShell(target), found != 0, found != workspace.ownProcessID,
           let migrated = workspace.describeProcess(found) {
            Log.input.info("Foreground migrated from the desktop to \(migrated.processName, privacy: .public) (PID \(found))")
            retarget(migrated)
            return nil
        }
        Log.input.warning("Foreground process changed mid-action: expected PID \(target.processId), found \(found)")
        return .failed(Self.foregroundChangedMessage(expected: target.processId, found: found))
    }

    private func checkForeground() throws {
        let expected = target.processId
        let found = workspace.frontmostProcessID() ?? 0
        guard found == expected else {
            throw ExecutionFailure(message: Self.foregroundChangedMessage(expected: expected, found: found))
        }
    }

    // MARK: - Click

    private func click(_ decision: AgentDecision, element: AccessibilityElement?) async throws -> ActionResult {
        let label = element?.displayLabel ?? decision.targetLabel ?? decision.targetId ?? ""
        var frame = element?.frame ?? .zero

        if let element, let handle = locate(element, decision: decision) {
            let available = ax.actionNames(of: handle)
            for action in AXRoleMapper.pressActions where available.contains(action) {
                if ax.performAction(action, on: handle) {
                    Log.input.debug("Clicked via \(action, privacy: .public)")
                    return .succeeded(message: "Clicked via \(action) on '\(label)'")
                }
            }
            if let fresh = ax.frame(of: handle), fresh.width > 0, fresh.height > 0 { frame = fresh }
        }

        let point: CGPoint
        if frame.width > 0, frame.height > 0 {
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else if element == nil, let x = decision.x, let y = decision.y {
            point = CGPoint(x: x, y: y)
            let bounds = target.windowBounds
            if !bounds.isEmpty && !bounds.contains(point) {
                return .failed("Cannot click at (\(x), \(y)): the point is outside the target window.")
            }
        } else {
            return .failed("Cannot click: target element not found or has empty bounding frame.")
        }

        guard input.click(at: point) else { return Self.inputFailure("mouse click") }
        Log.input.debug("Clicked via CGEvent at (\(Int(point.x)), \(Int(point.y)))")
        return .succeeded(message: "Clicked via CGEvent fallback at (\(Int(point.x)), \(Int(point.y)))")
    }

    // MARK: - Typing

    private func typeText(_ decision: AgentDecision, element: AccessibilityElement?, submit: Bool) async throws -> ActionResult {
        let text = decision.textValue ?? ""
        // An empty AXValue write or select-all + delete would silently erase the field.
        guard !text.isEmpty else { return .failed("No text to type.") }
        guard let element else { return try await typeIntoFocusedControl(text, submit: submit) }

        let label = element.displayLabel
        let secure = Self.isSecure(element)
        let handle = locate(element, decision: decision)
        let multiline = !TextEntryHeuristics.isTerminal(target.bundleIdentifier) && TextEntryHeuristics.isDocument(element)

        if multiline, TextEntryHeuristics.alreadyEndsWith(handle.flatMap { ax.value(of: $0) } ?? element.value, text) {
            return .succeeded(message: "'\(label)' already ends with the requested text; not typed again")
        }

        // 1. AX: focus + set the value of a single-line field. Replacing the whole value means text can never
        //    be duplicated; documents are never replaced wholesale.
        if let handle, !multiline, ax.isValueSettable(handle) {
            ax.setBool(kAXFocusedAttribute, true, on: handle)
            if ax.setValue(text, on: handle) {
                let readBack = ax.value(of: handle)
                if readBack == nil || readBack == text {
                    logTyped(text, via: "AXValue", secure: secure)
                    if submit {
                        try await ensureFocused(handle, frame: element.frame)
                        try await clock.sleep(seconds: 0.08)
                        guard input.pressKey(InputSimulator.KeyCode.returnKey, flags: []) else { return Self.inputFailure("Return key") }
                        return .succeeded(message: Self.submittedMessage(text, label: label, secure: secure))
                    }
                    return .succeeded(message: "Typed text via AXValue on '\(label)'")
                }
                Log.input.info("AXValue read-back did not match; falling back to keyboard entry")
            }
        }

        // 2. Keyboard: confirm focus, clear, then type Unicode events.
        if let handle {
            let app = ax.applicationElement(pid: target.processId)
            do {
                try await TextFieldFocus.prepare(
                    attempts: focusAttempts,
                    interval: focusInterval,
                    sleep: { try await self.clock.sleep(seconds: $0) },
                    check: { try self.checkForeground() },
                    probe: { self.isFocusConfirmed(handle, app: app) },
                    requestFocus: { self.ax.setBool(kAXFocusedAttribute, true, on: handle) },
                    click: { try self.clickToFocus(handle, fallbackFrame: element.frame) }
                )
            } catch let failure as TextFieldFocus.Failure {
                return .failed(failure.localizedDescription)
            }
        } else {
            let frame = element.frame
            guard frame.width > 0, frame.height > 0 else {
                return .failed("Cannot type: target element not found or has empty bounding frame.")
            }
            guard input.click(at: CGPoint(x: frame.midX, y: frame.midY)) else { return Self.inputFailure("mouse click") }
            try await clock.sleep(seconds: 0.06)
        }

        try await prepareCaret(multiline: multiline)
        try await clock.sleep(seconds: 0.03)
        guard input.typeText(text) else { return Self.inputFailure("keyboard") }
        logTyped(text, via: "keyboard", secure: secure)

        if submit {
            try await clock.sleep(seconds: 0.08)
            guard input.pressKey(InputSimulator.KeyCode.returnKey, flags: []) else { return Self.inputFailure("Return key") }
            return .succeeded(message: Self.submittedMessage(text, label: label, secure: secure))
        }
        return .succeeded(message: "Typed text via keyboard on '\(label)'")
    }

    /// Types into whatever control currently has keyboard focus (no target element).
    private func typeIntoFocusedControl(_ text: String, submit: Bool) async throws -> ActionResult {
        let app = ax.applicationElement(pid: target.processId)
        var secure = false
        var multiline = false
        if let focused = ax.focusedElement(of: app), case .node(let snapshot) = ax.snapshot(of: focused) {
            secure = TextEntryHeuristics.isSecure(role: snapshot.role, subrole: snapshot.subrole)
            let described = AccessibilityElement(
                id: "", role: AXRoleMapper.elementRole(role: snapshot.role, subrole: snapshot.subrole),
                label: AXRoleMapper.label(for: snapshot))
            multiline = !TextEntryHeuristics.isTerminal(target.bundleIdentifier) && TextEntryHeuristics.isDocument(described)
        }
        try await prepareCaret(multiline: multiline)
        try await clock.sleep(seconds: 0.03)
        guard input.typeText(text) else { return Self.inputFailure("keyboard") }
        logTyped(text, via: "keyboard (focused control)", secure: secure)
        if submit {
            try await clock.sleep(seconds: 0.06)
            guard input.pressKey(InputSimulator.KeyCode.returnKey, flags: []) else { return Self.inputFailure("Return key") }
        }
        return .succeeded(message: "Typed text into focused element")
    }

    /// Single-line fields: select-all + delete (⌃A ⌃K at a terminal prompt) so new text replaces rather than
    /// duplicates. Documents: move the caret to the end (⌘↓) and append, never wiping existing content.
    private func prepareCaret(multiline: Bool) async throws {
        if TextEntryHeuristics.isTerminal(target.bundleIdentifier) {
            try press(InputSimulator.KeyCode.a, flags: .maskControl)
            try press(InputSimulator.KeyCode.k, flags: .maskControl)
        } else if multiline {
            try press(InputSimulator.KeyCode.downArrow, flags: .maskCommand)
        } else {
            try press(InputSimulator.KeyCode.a, flags: .maskCommand)
            try await clock.sleep(seconds: 0.03)
            try press(InputSimulator.KeyCode.delete, flags: [])
        }
    }

    private func ensureFocused(_ handle: AXUIElement, frame: CGRect) async throws {
        let app = ax.applicationElement(pid: target.processId)
        guard !isFocusConfirmed(handle, app: app) else { return }
        try clickToFocus(handle, fallbackFrame: frame)
        try await clock.sleep(seconds: 0.06)
    }

    private func clickToFocus(_ handle: AXUIElement, fallbackFrame: CGRect) throws {
        let frame = ax.frame(of: handle).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackFrame
        guard frame.width > 0, frame.height > 0 else {
            throw ExecutionFailure(message: "The selected text field did not expose a clickable position.")
        }
        guard input.click(at: CGPoint(x: frame.midX, y: frame.midY)) else {
            throw ExecutionFailure(message: Self.inputFailure("mouse click").errorMessage ?? "")
        }
    }

    private func isFocusConfirmed(_ field: AXUIElement, app: AXUIElement) -> Bool {
        if let focused = ax.focusedElement(of: app) {
            // An explicit, different focused control takes precedence over a stale AXFocused flag.
            return TextFieldFocus.contains(focused, target: field, equal: { $0 == $1 }, parent: { self.ax.parent(of: $0) })
        }
        return ax.isFocused(field) == true
    }

    private func logTyped(_ text: String, via method: String, secure: Bool) {
        if secure {
            Log.input.info("Typed \(text.count) characters into a secure field via \(method, privacy: .public)")
        } else {
            Log.input.info("Typed '\(text, privacy: .private)' via \(method, privacy: .public)")
        }
    }

    // MARK: - Keys and scrolling

    private func pressKey(_ keyCode: CGKeyCode, name: String) -> ActionResult {
        guard input.pressKey(keyCode, flags: []) else { return Self.inputFailure("\(name) key") }
        return .succeeded(message: "Pressed \(name) key")
    }

    private func press(_ keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard input.pressKey(keyCode, flags: flags) else {
            throw ExecutionFailure(message: Self.inputFailure("keyboard").errorMessage ?? "")
        }
    }

    private func scroll(lines: Int, element: AccessibilityElement?, direction: String) -> ActionResult {
        guard input.scroll(lines: lines, at: scrollPoint(for: element)) else { return Self.inputFailure("scroll") }
        return .succeeded(message: "Scrolled \(direction)")
    }

    /// Scroll events go to the window under their location, so aim at the element or the target window
    /// rather than wherever the user's pointer happens to be.
    private func scrollPoint(for element: AccessibilityElement?) -> CGPoint? {
        if let frame = element?.frame, frame.width > 0, frame.height > 0 {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let target = self.target
        if let window = ax.focusedWindow(of: ax.applicationElement(pid: target.processId)),
           let frame = ax.frame(of: window), frame.width > 0, frame.height > 0 {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let bounds = target.windowBounds
        return bounds.isEmpty ? nil : CGPoint(x: bounds.midX, y: bounds.midY)
    }

    // MARK: - Launching

    private func openApp(_ decision: AgentDecision) async throws -> ActionResult {
        guard let appLauncher else { return .failed("AppLauncher is not configured.") }
        let name = (decision.targetId ?? decision.targetLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failed("OpenApp requires an application name.") }
        guard let newTarget = try await appLauncher.launchApp(named: name, launchCommand: nil) else {
            return .succeeded(message: "Launched application '\(name)'")
        }
        retarget(newTarget)
        return .targetChanged(newTarget, message: "Launched application '\(newTarget.processName)'")
    }

    private func openURL(_ decision: AgentDecision) async throws -> ActionResult {
        guard let appLauncher else { return .failed("AppLauncher is not configured.") }
        let raw = decision.textValue ?? decision.targetId ?? ""
        guard let url = UrlLauncherValidator.validatedWebURL(raw) else { return .failed("Invalid URL '\(raw)'") }
        guard let browser = try await appLauncher.launchURL(url) else {
            return .succeeded(message: "Opened URL '\(url.absoluteString)'")
        }
        retarget(browser)
        return .targetChanged(browser, message: "Opened URL '\(url.absoluteString)'")
    }

    // MARK: - Element resolution

    /// The AXUIElement behind `element`: the registry entry from the latest read (validated against the
    /// target process and role so a stale id is never acted on), else a hit-test at the element's centre
    /// walking up to five ancestors, like the Windows `FromPoint` + parent walk.
    private func locate(_ element: AccessibilityElement, decision: AgentDecision) -> AXUIElement? {
        guard element.source == "accessibility" else { return nil }
        let pid = target.processId
        let id = element.id.isEmpty ? (decision.targetId ?? "") : element.id
        if let handle = registry.element(for: id), matches(handle, element: element, pid: pid) {
            return handle
        }
        guard element.frame.width > 0, element.frame.height > 0,
              var current = ax.element(at: CGPoint(x: element.frame.midX, y: element.frame.midY),
                                       in: ax.applicationElement(pid: pid)) else { return nil }
        for _ in 0..<5 {
            if matches(current, element: element, pid: pid) { return current }
            guard let parent = ax.parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    private func matches(_ handle: AXUIElement, element: AccessibilityElement, pid: Int32) -> Bool {
        guard ax.processID(of: handle) == pid, let current = ax.roleAndSubrole(of: handle) else { return false }
        return AXRoleMapper.elementRole(role: current.role, subrole: current.subrole) == element.role
    }

    // MARK: - Messages

    struct ExecutionFailure: Error {
        let message: String
    }

    static let accessibilityRequiredMessage = "Accessibility permission is required to control other apps. "
        + "Enable GhostHand in System Settings > Privacy & Security > Accessibility."

    static func foregroundChangedMessage(expected: Int32, found: Int32) -> String {
        "Foreground process changed mid-action (expected PID \(expected), found \(found)). Execution aborted."
    }

    static func inputFailure(_ what: String) -> ActionResult {
        .failed("Could not post \(what) events. Check that GhostHand has Accessibility permission.")
    }

    static func submittedMessage(_ text: String, label: String, secure: Bool) -> String {
        secure
            ? "Typed text and submitted via Enter on '\(label)'"
            : "Typed '\(text)' and submitted via Enter on '\(label)'"
    }

    static func isSecure(_ element: AccessibilityElement?) -> Bool {
        guard let element else { return false }
        return TextEntryHeuristics.isSecure(role: element.role)
    }

    static func loggableText(_ text: String, secure: Bool) -> String {
        secure ? "[REDACTED]" : text
    }
}
