import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore
import Testing
@testable import GhostHandPlatform

private let pid: Int32 = 1234
private let fieldFrame = CGRect(x: 50, y: 50, width: 300, height: 24)

private func makeExecutor(
    target: AppTarget = AppTarget(processId: pid, processName: "Notes", bundleIdentifier: "com.apple.Notes"),
    input: FakeInputSink,
    workspace: FakeWorkspace,
    ax: FakeAXBackend = FakeAXBackend()
) -> MacActionExecutor {
    let executor = MacActionExecutor(target: target, dryRun: false, appLauncher: nil, registry: AXElementRegistry(),
                                     ax: ax, input: input, workspace: workspace, clock: InstantClock())
    executor.focusAttempts = 2
    return executor
}

@Suite struct PlatformReviewRegressionTests {
    @Test func unlabelledTextAreaMentioningSearchWordsIsStillADocument() {
        let body = AccessibilityElement(id: "e1", role: "AXTextArea", value: "Hi team, I'll find the Q3 numbers. We barely made it.")
        #expect(!TextEntryHeuristics.isSearchOrAddressBar(body))
        #expect(TextEntryHeuristics.isDocument(body))
        // Keywords only count as whole words of the label.
        #expect(!TextEntryHeuristics.isSearchOrAddressBar(AccessibilityElement(id: "e2", role: "AXTextField", label: "Barcode")))
        #expect(TextEntryHeuristics.isSearchOrAddressBar(AccessibilityElement(id: "e3", role: "AXTextArea", label: "Search")))
    }

    @Test func shortcutsFollowTheKeyboardLayout() async throws {
        let input = FakeInputSink()
        input.layout = ["a": 0x0C, "k": 0x28]  // AZERTY: "a" sits where US has "q"
        let executor = makeExecutor(input: input, workspace: FakeWorkspace(frontmost: pid, running: [pid]))

        _ = try await executor.execute(AgentDecision(operation: .typeText, textValue: "bonjour"), targetElement: nil)
        #expect(input.events.first == .key(0x0C, .maskCommand))
        #expect(!input.events.contains(.key(0x00, .maskCommand)))
    }

    @Test func typingStopsWhenAnotherAppTakesFocus() async throws {
        let input = FakeInputSink()
        let workspace = FakeWorkspace(frontmost: pid, running: [pid, 9999])
        input.beforeCharacter = { index in if index == 3 { workspace.frontmost = 9999 } }
        let executor = makeExecutor(input: input, workspace: workspace)

        let result = try await executor.execute(AgentDecision(operation: .typeText, textValue: "hello world"), targetElement: nil)
        #expect(!result.success)
        #expect(result.errorMessage?.contains("found 9999") == true)
        #expect(input.typedText == ["hel"])
    }

    @Test func typingStopsOnCancellation() async {
        let input = FakeInputSink()
        let executor = makeExecutor(input: input, workspace: FakeWorkspace(frontmost: pid, running: [pid]))
        input.beforeCharacter = { index in if index == 2 { withUnsafeCurrentTask { $0?.cancel() } } }

        let task = Task {
            try await executor.execute(AgentDecision(operation: .typeText, textValue: "long text"), targetElement: nil)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(input.typedText == ["lo"])
    }

    @Test func slowActivationIsAwaitedInsteadOfAborting() async throws {
        let input = FakeInputSink()
        let workspace = FakeWorkspace(frontmost: 1, running: [pid])  // GhostHand (pid 1) is frontmost
        workspace.activationBringsToFront = false
        workspace.frontmostSequence = [1, 1, 1, 1, pid]  // target arrives on the fourth poll
        let executor = makeExecutor(input: input, workspace: workspace)

        let result = try await executor.execute(AgentDecision(operation: .pressReturn), targetElement: nil)
        #expect(result.success)
        #expect(input.events == [.key(0x24, [])])
    }
}
