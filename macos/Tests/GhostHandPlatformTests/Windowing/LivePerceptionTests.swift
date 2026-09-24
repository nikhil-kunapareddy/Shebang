import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore
import Testing
@testable import GhostHandPlatform

/// Read-only checks against the real frontmost app. Opt in with `GHOSTHAND_LIVE_UI_TESTS=1`; needs a GUI
/// session with Accessibility (and Screen Recording for the OCR check). Nothing is clicked or typed.
@Suite(.enabled(if: LiveUI.enabled, "Set GHOSTHAND_LIVE_UI_TESTS=1 to run live UI tests"))
struct LivePerceptionTests {
    @Test func capturesTheFrontmostApp() throws {
        let tracker = FrontmostWindowTracker()
        let target = try #require(tracker.captureFrontmost())
        #expect(target.processId != getpid())
        #expect(!target.processName.isEmpty)
        #expect(tracker.activeTarget(current: target) != nil)
    }

    // RD01 equivalent against a real window: controls come back with roles/labels, ids resolve, no secure fields.
    @Test(.enabled(if: AXIsProcessTrusted(), "Accessibility permission required"))
    func readsTheFrontmostWindowTree() async throws {
        let target = try #require(FrontmostWindowTracker().captureFrontmost())
        let registry = AXElementRegistry()
        let elements = try await AXScreenReader(ocr: nil, registry: registry).readElements(target: target)
        #expect(!elements.isEmpty)
        #expect(!elements.contains { $0.role.contains("Secure") })
        let accessible = elements.filter { $0.source == "accessibility" }
        #expect(accessible.allSatisfy { registry.element(for: $0.id) != nil })
    }

    @Test(.enabled(if: CGPreflightScreenCaptureAccess(), "Screen Recording permission required"))
    func ocrReadsTheFrontmostWindow() async throws {
        let target = try #require(FrontmostWindowTracker().captureFrontmost())
        let elements = try await VisionOCRService().recognizeText(in: target)
        #expect(elements.allSatisfy { $0.source == "ocr" && $0.role == "OCRText" })
    }

    @Test func dryRunExecutionAgainstTheRealTargetSendsNothing() async throws {
        let target = try #require(FrontmostWindowTracker().captureFrontmost())
        let executor = MacActionExecutor(target: target, dryRun: true)
        let result = try await executor.execute(AgentDecision(operation: .pressReturn), targetElement: nil)
        #expect(result.success)
        #expect(result.message?.contains("[DRY RUN]") == true)
    }
}
