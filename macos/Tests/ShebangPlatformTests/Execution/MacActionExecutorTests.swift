import ApplicationServices
import CoreGraphics
import Foundation
import ShebangCore
import Testing
@testable import ShebangPlatform

private let targetPID: Int32 = 1234
private let notes = AppTarget(processId: targetPID, processName: "Notes", bundleIdentifier: "com.apple.Notes",
                              windowTitle: "Notes", windowBounds: CGRect(x: 0, y: 0, width: 1000, height: 800))

private struct Harness {
    let ax = FakeAXBackend()
    let input = FakeInputSink()
    let workspace: FakeWorkspace
    let clock = InstantClock()
    let registry = AXElementRegistry()
    let launcher = FakeAppLauncher()
    let executor: MacActionExecutor
    let window: AXUIElement

    init(target: AppTarget = notes, dryRun: Bool = false, frontmost: Int32? = targetPID, withLauncher: Bool = true) {
        workspace = FakeWorkspace(frontmost: frontmost, running: [target.processId, 555, 9999])
        window = ax.window(pid: target.processId, title: target.windowTitle, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        executor = MacActionExecutor(target: target, dryRun: dryRun, appLauncher: withLauncher ? launcher : nil,
                                     registry: registry, ax: ax, input: input, workspace: workspace, clock: clock)
        executor.focusAttempts = 2
    }

    func register(_ handles: [String: AXUIElement]) { registry.replaceAll(handles) }

    func run(_ operation: AgentOperation, _ element: AccessibilityElement? = nil, text: String? = nil,
             targetId: String? = nil) async throws -> ActionResult {
        let decision = AgentDecision(operation: operation, targetId: targetId ?? element?.id,
                                     targetLabel: element?.displayLabel, textValue: text)
        return try await executor.execute(decision, targetElement: element)
    }
}

private let buttonFrame = CGRect(x: 100, y: 100, width: 80, height: 30)
private let fieldFrame = CGRect(x: 200, y: 50, width: 300, height: 24)

@Suite struct MacActionExecutorTests {
    // MARK: Dry run and trivial operations

    // Dry-run mode plans without injecting input.
    @Test func dryRunDoesNotTouchTheSystem() async throws {
        let h = Harness(dryRun: true, frontmost: 9999)
        let element = AccessibilityElement(id: "btn1", role: "AXButton", label: "Submit Form", frame: buttonFrame)

        let click = try await h.run(.click, element)
        #expect(click.success)
        #expect(click.message?.contains("[DRY RUN]") == true)

        let open = try await h.executor.execute(AgentDecision(operation: .openApp, targetId: "Safari"), targetElement: nil)
        #expect(open.success)
        #expect(open.newTarget == nil)

        _ = try await h.run(.typeAndEnter, element, text: "hello")
        #expect(h.input.events.isEmpty)
        #expect(h.workspace.activations.isEmpty)
        #expect(h.ax.performedActions.isEmpty)
        #expect(h.ax.setValues.isEmpty)
        #expect(h.launcher.launchedApps.isEmpty)
        #expect(h.clock.sleeps == [0.15, 0.15, 0.15])
    }

    @Test func doneAskUserAndWaitNeedNoInput() async throws {
        let h = Harness(frontmost: 9999)
        #expect(try await h.run(.done).message == "Task completed")
        #expect(try await h.run(.askUser).message == "User consultation requested")
        let wait = try await h.run(.wait)
        #expect(wait.success && wait.message == "Waited 1 second")
        #expect(h.clock.sleeps == [1])
        #expect(h.input.events.isEmpty)
    }

    @Test func blockedIsReportedAsFailure() async throws {
        let h = Harness()
        let result = try await h.executor.execute(AgentDecision(operation: .blocked, reason: "login required"), targetElement: nil)
        #expect(!result.success)
        #expect(result.errorMessage?.contains("login required") == true)
        #expect(h.input.events.isEmpty)
    }

    // MARK: Focus safety

    // The user switched to another app mid-run — abort without stealing focus back.
    @Test func foregroundChangeAbortsBeforeInput() async throws {
        let h = Harness(frontmost: 9999)
        let result = try await h.run(.pressReturn)
        #expect(!result.success)
        #expect(result.errorMessage == "Foreground process changed mid-action (expected PID 1234, found 9999). Execution aborted.")
        #expect(h.input.events.isEmpty)
        #expect(h.workspace.activations.isEmpty)
    }

    @Test func reactivatesTargetWhenShebangHoldsFocus() async throws {
        let h = Harness(frontmost: 1)  // Shebang's own panel
        let result = try await h.run(.pressReturn)
        #expect(result.success)
        #expect(h.workspace.activations.map(\.processId) == [targetPID])
        #expect(h.input.events == [.key(0x24, [])])
    }

    @Test func failedReactivationAborts() async throws {
        let h = Harness(frontmost: nil)
        h.workspace.activationBringsToFront = false
        let result = try await h.run(.pressTab)
        #expect(!result.success)
        #expect(result.errorMessage?.contains("expected PID 1234, found 0") == true)
        #expect(h.input.events.isEmpty)
    }

    @Test func desktopTargetMigratesToTheAppThatTookFocus() async throws {
        let desktop = AppTarget(processId: 300, processName: "Finder", bundleIdentifier: "com.apple.finder")
        let h = Harness(target: desktop, frontmost: 555)
        h.workspace.running.insert(300)
        let safari = AppTarget(processId: 555, processName: "Safari", bundleIdentifier: "com.apple.Safari")
        h.workspace.described[555] = safari

        // The action was chosen from the desktop, so the loop re-reads Safari before anything is pressed.
        let result = try await h.run(.pressSpace)
        #expect(result.success)
        #expect(result.newTarget == safari)
        #expect(h.executor.target == safari)
        #expect(h.input.events.isEmpty)
    }

    @Test func missingAccessibilityPermissionFailsClearly() async throws {
        let h = Harness()
        h.ax.isTrusted = false
        let result = try await h.run(.pressEscape)
        #expect(!result.success)
        #expect(result.errorMessage?.contains("Accessibility permission") == true)
        #expect(h.input.events.isEmpty)
    }

    @Test func quitTargetFailsClearly() async throws {
        let h = Harness()
        h.workspace.running.remove(targetPID)
        let result = try await h.run(.pressReturn)
        #expect(!result.success)
        #expect(result.errorMessage?.contains("no longer running") == true)
    }

    @Test func retargetChangesTheExpectedProcess() async throws {
        let h = Harness(frontmost: 555)
        #expect(try await h.run(.pressReturn).success == false)
        h.executor.retarget(AppTarget(processId: 555, processName: "Safari"))
        #expect(try await h.run(.pressReturn).success)
    }

    // MARK: Click

    @Test func clickPrefersAXPressFromTheRegistry() async throws {
        let h = Harness()
        let button = h.ax.add("AXButton", title: "Submit Form", frame: buttonFrame, actions: ["AXPress"], to: h.window)
        h.register(["e1": button])
        let element = AccessibilityElement(id: "e1", role: "AXButton", label: "Submit Form", frame: buttonFrame, actions: ["AXPress"])

        let result = try await h.run(.click, element)
        #expect(result.success)
        #expect(result.message == "Clicked via AXPress on 'Submit Form'")
        #expect(h.ax.performedActions.map(\.action) == ["AXPress"])
        #expect(h.ax.performedActions.first?.element == button)
        #expect(h.input.events.isEmpty)
    }

    @Test func clickFallsBackToCGEventAtTheCurrentFrame() async throws {
        let h = Harness()
        let moved = CGRect(x: 300, y: 300, width: 40, height: 20)
        let button = h.ax.add("AXButton", title: "Go", frame: moved, actions: ["AXPress"], to: h.window)
        h.ax.failingActions = ["AXPress"]
        h.register(["e1": button])
        let element = AccessibilityElement(id: "e1", role: "AXButton", label: "Go", frame: buttonFrame, actions: ["AXPress"])

        let result = try await h.run(.click, element)
        #expect(result.success)
        #expect(h.input.events == [.click(CGPoint(x: 320, y: 310))])
    }

    @Test func staleOrForeignRegistryEntriesAreNotActedOn() async throws {
        let h = Harness()
        let text = h.ax.add("AXStaticText", value: "Submit", frame: buttonFrame, actions: ["AXPress"], to: h.window)
        let otherWindow = h.ax.window(pid: 9999)
        let foreign = h.ax.add("AXButton", title: "Submit", frame: buttonFrame, actions: ["AXPress"], to: otherWindow)
        h.register(["e1": text, "e2": foreign])

        for id in ["e1", "e2"] {
            let element = AccessibilityElement(id: id, role: "AXButton", label: "Submit", frame: buttonFrame)
            #expect(try await h.run(.click, element).success)
        }
        #expect(h.ax.performedActions.isEmpty)
        #expect(h.input.events == [.click(CGPoint(x: 140, y: 115)), .click(CGPoint(x: 140, y: 115))])
    }

    @Test func hitTestWalksUpToTheMatchingAncestor() async throws {
        let h = Harness()
        let button = h.ax.add("AXButton", title: "Play", frame: buttonFrame, actions: ["AXPress"], to: h.window)
        let label = h.ax.add("AXStaticText", value: "Play", frame: buttonFrame, to: button)
        h.ax.hitTestResult = label
        let element = AccessibilityElement(id: "e7", role: "AXButton", label: "Play", frame: buttonFrame)

        let result = try await h.run(.click, element)
        #expect(result.message == "Clicked via AXPress on 'Play'")
        #expect(h.ax.performedActions.first?.element == button)
    }

    @Test func clickWithoutFrameOrHandleFails() async throws {
        let h = Harness()
        let result = try await h.run(.click, AccessibilityElement(id: "e1", role: "AXButton", label: "Ghost"))
        #expect(result.errorMessage == "Cannot click: target element not found or has empty bounding frame.")
        #expect(try await h.run(.click).success == false)
        #expect(h.input.events.isEmpty)
    }

    @Test func clickTextClicksTheCentreOfOCRText() async throws {
        let h = Harness()
        let text = AccessibilityElement(id: "e3", role: "OCRText", label: "Sign up",
                                        frame: CGRect(x: 100, y: 200, width: 50, height: 20), source: "ocr")
        let result = try await h.run(.clickText, text)
        #expect(result.success)
        #expect(h.input.events == [.click(CGPoint(x: 125, y: 210))])
        #expect(h.ax.performedActions.isEmpty)
    }

    // MARK: Typing

    private func field(_ h: Harness, label: String, settable: Bool = true, value: String = "") -> (AXUIElement, AccessibilityElement) {
        let handle = h.ax.add("AXTextField", description: label, value: value, frame: fieldFrame, settable: settable, to: h.window)
        h.register(["e1": handle])
        return (handle, AccessibilityElement(id: "e1", role: "AXTextField", label: label, value: value, frame: fieldFrame))
    }

    @Test func typeTextSetsAXValueWithoutKeystrokes() async throws {
        let h = Harness()
        let (handle, element) = field(h, label: "Name", value: "Old text")

        let result = try await h.run(.typeText, element, text: "Shebang Automated Typing")
        #expect(result.success)
        #expect(h.ax.node(handle)?.value == "Shebang Automated Typing")
        #expect(h.ax.setValues.map(\.value) == ["Shebang Automated Typing"])
        #expect(h.ax.setBools.contains { $0.attribute == kAXFocusedAttribute && $0.element == handle })
        #expect(h.input.events.isEmpty)
    }

    @Test func typingIntoSearchFieldsAutoSubmits() async throws {
        let h = Harness()
        let (handle, element) = field(h, label: "Search")
        h.ax.setFocusedElement(handle, pid: targetPID)

        let result = try await h.run(.typeText, element, text: "Adele")
        #expect(result.message == "Typed 'Adele' and submitted via Enter on 'Search'")
        #expect(h.input.events == [.key(0x24, [])])
    }

    @Test func typeAndEnterAlwaysSubmitsAndClicksWhenFocusIsElsewhere() async throws {
        let h = Harness()
        let (_, element) = field(h, label: "Name")
        let other = h.ax.add("AXButton", title: "Other", frame: buttonFrame, to: h.window)
        h.ax.setFocusedElement(other, pid: targetPID)

        let result = try await h.run(.typeAndEnter, element, text: "Ada")
        #expect(result.success)
        #expect(h.input.events == [.click(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)), .key(0x24, [])])
    }

    @Test func readBackMismatchFallsBackToClearAndType() async throws {
        let h = Harness()
        let (handle, element) = field(h, label: "Message")
        h.ax.readBackOverride = .some("Message: autocorrected")
        h.ax.setFocusedElement(handle, pid: targetPID)

        let result = try await h.run(.typeText, element, text: "hello")
        #expect(result.message == "Typed text via keyboard on 'Message'")
        #expect(h.input.events == [.key(0x00, .maskCommand), .key(0x33, []), .type("hello")])
    }

    @Test func keyboardEntryConfirmsFocusViaAXBeforeClicking() async throws {
        let h = Harness()
        let (handle, element) = field(h, label: "Notes", settable: false)
        h.ax.onFocusRequest = { requested in h.ax.setFocusedElement(requested, pid: targetPID) }

        let result = try await h.run(.typeText, element, text: "abc")
        #expect(result.success)
        #expect(h.ax.setBools.contains { $0.attribute == kAXFocusedAttribute && $0.element == handle })
        #expect(h.input.events == [.key(0x00, .maskCommand), .key(0x33, []), .type("abc")])
    }

    @Test func unconfirmedFocusNeverTypes() async throws {
        let h = Harness()
        let (_, element) = field(h, label: "Notes", settable: false)
        let other = h.ax.add("AXButton", title: "Other", frame: buttonFrame, to: h.window)
        h.ax.setFocusedElement(other, pid: targetPID)

        let result = try await h.run(.typeText, element, text: "secret plan")
        #expect(!result.success)
        #expect(result.errorMessage?.contains("did not report keyboard focus") == true)
        #expect(h.input.typedText.isEmpty)
        #expect(h.input.events == [.click(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY))])
    }

    @Test func appSwitchDuringFocusWaitStopsTyping() async throws {
        let h = Harness()
        let (_, element) = field(h, label: "Notes", settable: false)
        // prepareForInput sees the target; the focus probe then sees another app.
        h.workspace.frontmostSequence = [targetPID, 9999]

        let result = try await h.run(.typeText, element, text: "abc")
        #expect(result.errorMessage?.contains("Foreground process changed mid-action") == true)
        #expect(h.input.typedText.isEmpty)
    }

    @Test func emptyTextNeverClearsAField() async throws {
        let h = Harness()
        let (handle, element) = field(h, label: "Name", value: "Keep me")
        let result = try await h.run(.typeText, element, text: nil)
        #expect(result.errorMessage == "No text to type.")
        #expect(h.ax.node(handle)?.value == "Keep me")
        #expect(h.input.events.isEmpty)
    }

    @Test func unresolvedElementIsClickedThenCleared() async throws {
        let h = Harness()
        let element = AccessibilityElement(id: "e9", role: "AXTextField", label: "Title", frame: fieldFrame)
        let result = try await h.run(.typeText, element, text: "Report")
        #expect(result.success)
        #expect(h.input.events == [
            .click(CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)), .key(0x00, .maskCommand), .key(0x33, []), .type("Report"),
        ])
    }

    @Test func typingWithoutElementTargetsTheFocusedControl() async throws {
        let h = Harness()
        let result = try await h.run(.typeAndEnter, text: "hello")
        #expect(result.message == "Typed text into focused element")
        #expect(h.input.events == [.key(0x00, .maskCommand), .key(0x33, []), .type("hello"), .key(0x24, [])])
    }

    @Test func documentsAreAppendedToNeverReplaced() async throws {
        let h = Harness()
        let body = h.ax.add("AXTextArea", description: "Note body", value: "Shopping list", frame: fieldFrame,
                            settable: true, to: h.window)
        h.register(["e1": body])
        h.ax.setFocusedElement(body, pid: targetPID)
        let element = AccessibilityElement(id: "e1", role: "AXTextArea", label: "Note body", value: "Shopping list", frame: fieldFrame)

        let result = try await h.run(.typeText, element, text: "milk")
        #expect(result.success)
        #expect(h.ax.setValues.isEmpty)
        #expect(h.input.events == [.key(0x7D, .maskCommand), .type("milk")])
        #expect(!h.input.events.contains(.key(0x00, .maskCommand)))
    }

    @Test func searchBoxesExposedAsTextAreasAreStillReplaced() async throws {
        let h = Harness()
        let box = h.ax.add("AXTextArea", description: "Search or ask a question", value: "old query", frame: fieldFrame,
                           settable: true, to: h.window)
        h.register(["e1": box])
        h.ax.setFocusedElement(box, pid: targetPID)
        let element = AccessibilityElement(id: "e1", role: "AXTextArea", label: "Search or ask a question",
                                           value: "old query", frame: fieldFrame)

        let result = try await h.run(.typeText, element, text: "lofi beats")
        #expect(result.success)
        #expect(h.ax.node(box)?.value == "lofi beats")
        #expect(h.input.events == [.key(0x24, [])])
    }

    @Test func repeatedDocumentTextIsNotTypedTwice() async throws {
        let h = Harness()
        let body = h.ax.add("AXTextArea", value: "Dear team,\nThanks for the update.", frame: fieldFrame, to: h.window)
        h.register(["e1": body])
        let element = AccessibilityElement(id: "e1", role: "AXTextArea", label: "Message", frame: fieldFrame)

        let result = try await h.run(.typeText, element, text: "Thanks for the update.")
        #expect(result.success)
        #expect(result.message?.contains("not typed again") == true)
        #expect(h.input.events.isEmpty)
    }

    @Test func focusedDocumentIsNotWipedWhenNoElementIsGiven() async throws {
        let h = Harness()
        let body = h.ax.add("AXTextArea", value: "Draft", frame: fieldFrame, to: h.window)
        h.ax.setFocusedElement(body, pid: targetPID)
        _ = try await h.run(.typeText, text: " more")
        #expect(h.input.events == [.key(0x7D, .maskCommand), .type(" more")])
    }

    @Test func terminalsClearWithReadlineKeys() async throws {
        let terminal = AppTarget(processId: targetPID, processName: "Terminal", bundleIdentifier: "com.apple.Terminal")
        let h = Harness(target: terminal)
        _ = try await h.run(.typeText, text: "ls -la")
        #expect(h.input.events == [.key(0x00, .maskControl), .key(0x28, .maskControl), .type("ls -la")])
    }

    @Test func secureFieldTextIsNeverEchoed() async throws {
        let h = Harness()
        let element = AccessibilityElement(id: "e1", role: "AXSecureTextField", label: "Password", frame: fieldFrame)
        let result = try await h.run(.typeAndEnter, element, text: "hunter2")
        #expect(result.success)
        #expect(result.message?.contains("hunter2") == false)
        #expect(MacActionExecutor.loggableText("hunter2", secure: true) == "[REDACTED]")
    }

    // MARK: Keys and scrolling

    @Test func keysMapToMacVirtualKeyCodes() async throws {
        let h = Harness()
        for operation in [AgentOperation.pressReturn, .pressTab, .pressEscape, .pressSpace, .pressMediaPlay] {
            #expect(try await h.run(operation).success)
        }
        #expect(h.input.events == [.key(0x24, []), .key(0x30, []), .key(0x35, []), .key(0x31, []), .mediaPlayPause])
    }

    @Test func scrollingTargetsTheElementOrWindowCentre() async throws {
        let h = Harness()
        _ = try await h.run(.scrollDown)
        let element = AccessibilityElement(id: "e1", role: "AXList", label: "Results", frame: CGRect(x: 0, y: 100, width: 200, height: 400))
        _ = try await h.run(.scrollUp, element)
        #expect(h.input.events == [.scroll(-5, CGPoint(x: 500, y: 400)), .scroll(5, CGPoint(x: 100, y: 300))])
    }

    @Test func inputPostingFailuresAreReported() async throws {
        let h = Harness()
        h.input.succeeds = false
        let result = try await h.run(.pressReturn)
        #expect(!result.success)
        #expect(result.errorMessage?.contains("Accessibility permission") == true)
    }

    // MARK: Launching

    @Test func openAppRequiresALauncher() async throws {
        let h = Harness(withLauncher: false)
        let result = try await h.executor.execute(AgentDecision(operation: .openApp, targetId: "Safari"), targetElement: nil)
        #expect(result.errorMessage == "AppLauncher is not configured.")
    }

    @Test func openAppRetargetsWithoutForegroundCheck() async throws {
        let h = Harness(frontmost: 9999)
        let safari = AppTarget(processId: 555, processName: "Safari", bundleIdentifier: "com.apple.Safari")
        h.launcher.appResult = safari

        let result = try await h.executor.execute(AgentDecision(operation: .openApp, targetId: "Safari", targetLabel: "Safari"),
                                                  targetElement: nil)
        #expect(result.success)
        #expect(result.newTarget == safari)
        #expect(result.message == "Launched application 'Safari'")
        #expect(h.launcher.launchedApps == ["Safari"])
        #expect(h.executor.target == safari)

        h.workspace.frontmost = 555
        #expect(try await h.run(.pressReturn).success)
    }

    @Test func openAppWithoutResolvedTargetStillSucceeds() async throws {
        let h = Harness()
        let result = try await h.executor.execute(AgentDecision(operation: .openApp, targetLabel: "Notes"), targetElement: nil)
        #expect(result.success)
        #expect(result.newTarget == nil)
        #expect(h.executor.target == notes)
    }

    @Test func launcherErrorsBecomeFailures() async throws {
        let h = Harness()
        h.launcher.error = FakeError(message: "No application named Foo")
        let result = try await h.executor.execute(AgentDecision(operation: .openApp, targetId: "Foo"), targetElement: nil)
        #expect(result.errorMessage == "No application named Foo")
    }

    @Test func openUrlValidatesAndRetargets() async throws {
        let h = Harness()
        let browser = AppTarget(processId: 777, processName: "Safari")
        h.launcher.urlResult = browser

        let result = try await h.executor.execute(
            AgentDecision(operation: .openUrl, targetId: "https://example.com", textValue: "https://example.com/docs"),
            targetElement: nil)
        #expect(result.newTarget == browser)
        #expect(h.launcher.launchedURLs.map(\.absoluteString) == ["https://example.com/docs"])

        let invalid = try await h.executor.execute(AgentDecision(operation: .openUrl, textValue: "javascript:alert(1)"),
                                                   targetElement: nil)
        #expect(invalid.errorMessage == "Invalid URL 'javascript:alert(1)'")
        #expect(h.launcher.launchedURLs.count == 1)
    }

    @Test func cancellationPropagates() async {
        let h = Harness()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await h.run(.wait)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
