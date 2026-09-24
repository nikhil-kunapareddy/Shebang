import CoreGraphics
import Foundation
import ShebangCore
import Testing
@testable import ShebangPlatform

/// Builds events without posting them, so no permission is needed and nothing moves on screen.
@Suite struct InputSimulatorTests {
    @Test func unicodeTypingEventsHaveNoShortcutModifiers() throws {
        for character: Character in ["a", "é", "🎵", "👩‍💻"] {
            let (down, up) = try #require(InputSimulator.unicodeEvents(for: character))
            #expect(down.flags == [])
            #expect(up.flags == [])
            #expect(down.getIntegerValueField(.keyboardEventKeycode) == 0)
            var buffer = [UniChar](repeating: 0, count: 16)
            var count = 0
            down.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &count, unicodeString: &buffer)
            #expect(String(utf16CodeUnits: buffer, count: count) == String(character))
        }
    }

    @Test func keyEventsCarryKeyCodeAndModifiers() throws {
        let (down, up) = try #require(InputSimulator.keyEvents(InputSimulator.KeyCode.a, flags: .maskCommand))
        #expect(down.getIntegerValueField(.keyboardEventKeycode) == 0x00)
        #expect(down.type == .keyDown)
        #expect(up.type == .keyUp)
        #expect(down.flags.contains(.maskCommand))
        #expect(up.flags.contains(.maskCommand))
    }

    @Test func clickEventsTargetTheGlobalPoint() throws {
        let point = CGPoint(x: -1200, y: 340)  // display left of the primary one
        let events = try #require(InputSimulator.clickEvents(at: point))
        #expect(events.move.type == .mouseMoved)
        #expect(events.down.type == .leftMouseDown)
        #expect(events.up.type == .leftMouseUp)
        #expect(events.down.location == point)
        #expect(events.down.getIntegerValueField(.mouseEventClickState) == 1)
    }

    @Test func scrollEventsUsePositiveLinesForUp() throws {
        let up = try #require(InputSimulator.scrollEvent(lines: 5, at: CGPoint(x: 400, y: 300)))
        let down = try #require(InputSimulator.scrollEvent(lines: -5, at: nil))
        #expect(up.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 5)
        #expect(down.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -5)
        #expect(up.location == CGPoint(x: 400, y: 300))
    }

    @Test func mediaKeyUsesSystemDefinedPlayEvent() throws {
        #expect(InputSimulator.mediaKeyData1(keyType: 16, keyDown: true) == 0x10_0A00)
        #expect(InputSimulator.mediaKeyData1(keyType: 16, keyDown: false) == 0x10_0B00)
        let event = try #require(InputSimulator.mediaKeyEvent(keyType: InputSimulator.mediaKeyPlay, keyDown: true))
        #expect(event.type.rawValue == 14)  // NX_SYSDEFINED
    }

    @Test func virtualKeyCodesMatchCarbon() {
        #expect(InputSimulator.KeyCode.returnKey == 0x24)
        #expect(InputSimulator.KeyCode.tab == 0x30)
        #expect(InputSimulator.KeyCode.space == 0x31)
        #expect(InputSimulator.KeyCode.delete == 0x33)
        #expect(InputSimulator.KeyCode.escape == 0x35)
    }
}

@Suite struct TextEntryHeuristicsTests {
    @Test func searchAndAddressBarsAutoSubmit() {
        #expect(TextEntryHeuristics.isSearchOrAddressBar(AccessibilityElement(id: "e1", role: "AXTextField", label: "Address and Search")))
        #expect(TextEntryHeuristics.isSearchOrAddressBar(AccessibilityElement(id: "e1", role: "AXComboBox", label: "Search or enter website name")))
        #expect(TextEntryHeuristics.isSearchOrAddressBar(AccessibilityElement(id: "e1", role: "AXSearchField")))
        #expect(!TextEntryHeuristics.isSearchOrAddressBar(AccessibilityElement(id: "e1", role: "AXTextField", label: "First name")))
        #expect(!TextEntryHeuristics.isSearchOrAddressBar(nil))
    }

    @Test func multilineDocumentsAndRepeatedTextAreRecognised() {
        #expect(TextEntryHeuristics.isMultiline(role: "AXTextArea"))
        #expect(TextEntryHeuristics.isMultiline(role: "Document"))
        #expect(!TextEntryHeuristics.isMultiline(role: "AXTextField"))
        #expect(TextEntryHeuristics.isDocument(AccessibilityElement(id: "e1", role: "AXTextArea", label: "Note body")))
        #expect(!TextEntryHeuristics.isDocument(AccessibilityElement(id: "e1", role: "AXTextArea", label: "Search or ask a question")))
        #expect(!TextEntryHeuristics.isDocument(AccessibilityElement(id: "e1", role: "AXTextField", label: "Name")))
        #expect(TextEntryHeuristics.alreadyEndsWith("Hello world\n", "world"))
        #expect(!TextEntryHeuristics.alreadyEndsWith("Hello world", "Hello"))
        #expect(!TextEntryHeuristics.alreadyEndsWith(nil, "x"))
        #expect(!TextEntryHeuristics.alreadyEndsWith("anything", "  "))
    }

    @Test func terminalsAndSecureRolesAreRecognised() {
        #expect(TextEntryHeuristics.isTerminal("com.apple.Terminal"))
        #expect(TextEntryHeuristics.isTerminal("com.googlecode.iterm2"))
        #expect(!TextEntryHeuristics.isTerminal("com.apple.Notes"))
        #expect(TextEntryHeuristics.isSecure(role: "AXSecureTextField"))
        #expect(TextEntryHeuristics.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(!TextEntryHeuristics.isSecure(role: "AXTextField"))
    }
}
