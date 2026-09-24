import Foundation
import Testing
@testable import ShebangCore

@Suite struct ModelTests {
    @Test func displayRoleStripsAXPrefix() {
        #expect(AccessibilityElement(id: "1", role: "AXButton").displayRole == "Button")
        #expect(AccessibilityElement(id: "2", role: "OCRText").displayRole == "OCRText")
    }

    @Test func displayLabelFallsBackToValue() {
        let element = AccessibilityElement(id: "1", role: "AXTextField", label: "  ", value: "hello")
        #expect(element.displayLabel == "hello")
    }

    @Test func compactDescriptionTruncates() {
        let element = AccessibilityElement(id: "1", role: "AXStaticText", label: String(repeating: "a", count: 200))
        #expect(element.compactDescription(maxChars: 10) == "aaaaaaaaaa...")
    }

    @Test func operationRawValuesMatchWindowsBuild() {
        #expect(AgentOperation.typeAndEnter.rawValue == "TypeAndEnter")
        #expect(AgentOperation.openUrl.rawValue == "OpenUrl")
    }
}
