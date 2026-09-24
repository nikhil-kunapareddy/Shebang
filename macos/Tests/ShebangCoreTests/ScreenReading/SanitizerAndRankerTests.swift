import CoreGraphics
import Testing
@testable import ShebangCore

@Suite struct SecretSanitizerTests {
    @Test func passwordFieldsAndSecretsAreRedacted() {
        #expect(SecretSanitizer.sanitize("SuperSecretP@ssword123!", isPassword: true) == "[PASSWORD]")

        let card = SecretSanitizer.sanitize("Please bill credit card 4111 2222 3333 4444 for $50")
        #expect(!card.contains("4111 2222 3333 4444"))
        #expect(card.contains("[REDACTED_CARD]"))

        let key = SecretSanitizer.sanitize("Gateway token is vck_dummy_test_key_sample1234567890abcdef")
        #expect(!key.contains("vck_dummy_test_key_sample1234567890abcdef"))
        #expect(key.contains("[REDACTED_KEY]"))

        let bearer = SecretSanitizer.sanitize("Authorization: Bearer my_secret_token_1234567890_abcdef")
        #expect(!bearer.contains("my_secret_token_1234567890_abcdef"))
        #expect(bearer.contains("Bearer [REDACTED]"))
    }

    @Test func emptyAndNilInputs() {
        #expect(SecretSanitizer.sanitize(nil) == "")
        #expect(SecretSanitizer.sanitize("hello") == "hello")
    }
}

@Suite struct ElementRankerTests {
    @Test func capsCandidatesWithDeterministicIds() {
        let raw = (0..<100).map { i in
            AccessibilityElement(
                id: "raw_\(i)",
                role: i % 3 == 0 ? "AXButton" : i % 3 == 1 ? "AXTextField" : "AXStaticText",
                label: "Item \(i)",
                frame: CGRect(x: 10 + (i % 20) * 10, y: 10 + (i / 20) * 10, width: 50, height: 20))
        }
        var options = ScreenReaderOptions()
        options.maxCandidates = 40

        let run1 = ElementRanker.rankAndFilter(raw, options: options)
        let run2 = ElementRanker.rankAndFilter(raw, options: options)
        #expect(run1.count == 40)
        #expect(run1.first?.id == "e1")
        #expect(run1.last?.id == "e40")
        #expect(run1 == run2)
        #expect(run1.allSatisfy { ElementRanker.isInteractive($0.role) })
    }

    @Test func focusedElementRanksFirst() {
        let elements = [
            AccessibilityElement(id: "a", role: "AXButton", label: "OK", frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
            AccessibilityElement(id: "b", role: "AXStaticText", label: "Status", focused: true,
                                 frame: CGRect(x: 0, y: 50, width: 10, height: 10)),
        ]
        #expect(ElementRanker.rankAndFilter(elements, options: .default).first?.label == "Status")
    }

    @Test func offscreenAndDisabledFiltering() {
        let elements = [
            AccessibilityElement(id: "on1", role: "AXButton", label: "Visible Button", frame: CGRect(x: 10, y: 10, width: 100, height: 30)),
            AccessibilityElement(id: "off1", role: "AXButton", label: "Zero Size", frame: .zero),
            AccessibilityElement(id: "dis1", role: "AXButton", label: "Disabled Button", enabled: false,
                                 frame: CGRect(x: 10, y: 50, width: 100, height: 30)),
        ]

        var offscreenOnly = ScreenReaderOptions()
        offscreenOnly.filterOffscreen = true
        let labels1 = ElementRanker.rankAndFilter(elements, options: offscreenOnly).map(\.label)
        #expect(labels1.contains("Visible Button"))
        #expect(labels1.contains("Disabled Button"))
        #expect(!labels1.contains("Zero Size"))

        var disabledOnly = ScreenReaderOptions()
        disabledOnly.filterOffscreen = false
        disabledOnly.filterDisabled = true
        let labels2 = ElementRanker.rankAndFilter(elements, options: disabledOnly).map(\.label)
        #expect(!labels2.contains("Disabled Button"))
        #expect(labels2.contains("Visible Button"))
    }

    @Test func interactiveRolesCoverMacAndWindowsNames() {
        #expect(ElementRanker.isInteractive("AXButton"))
        #expect(ElementRanker.isInteractive("AXTextField"))
        #expect(ElementRanker.isInteractive("Edit"))
        #expect(!ElementRanker.isInteractive("AXGroup"))
    }
}
