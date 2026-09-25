import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ShebangCore

/// Synthetic input via CGEvent. Coordinates are global, top-left-origin points — the same space as AX frames.
/// Posting requires Accessibility permission; without it every call logs and returns `false` instead of silently
/// dropping events.
public enum InputSimulator {
    /// macOS virtual key codes (Carbon `kVK_*`). Letter codes are US-layout positions: use
    /// `keyCode(for:)` for shortcuts so they match the user's layout.
    public enum KeyCode {
        public static let a: CGKeyCode = 0x00
        public static let k: CGKeyCode = 0x28
        public static let returnKey: CGKeyCode = 0x24
        public static let tab: CGKeyCode = 0x30
        public static let space: CGKeyCode = 0x31
        public static let delete: CGKeyCode = 0x33
        public static let escape: CGKeyCode = 0x35
        public static let downArrow: CGKeyCode = 0x7D
    }

    /// `NX_KEYTYPE_PLAY` from IOKit/hidsystem/ev_keymap.h.
    static let mediaKeyPlay: Int = 16

    public static func click(at point: CGPoint) -> Bool {
        guard canPost("click"), let events = clickEvents(at: point) else { return false }
        events.move.post(tap: .cghidEventTap)
        usleep(15_000)  // let hover state settle before pressing
        events.down.post(tap: .cghidEventTap)
        events.up.post(tap: .cghidEventTap)
        return true
    }

    /// Key code that types `character` in the user's current layout, falling back to the US position.
    public static func keyCode(for character: Character) -> CGKeyCode {
        if let code = KeyboardLayout.keyCode(for: character) { return code }
        switch character.lowercased() {
        case "a": return KeyCode.a
        case "k": return KeyCode.k
        default: return KeyCode.a
        }
    }

    /// Types `text` as Unicode keyboard events, one grapheme at a time; the clipboard is never touched.
    /// `shouldContinue` runs before every character so a kill switch or focus change stops typing at once.
    public static func typeText(_ text: String, shouldContinue: () -> Bool) -> Bool {
        guard !text.isEmpty else { return true }
        guard canPost("typeText") else { return false }
        for character in text {
            guard shouldContinue() else { return false }
            guard let (down, up) = unicodeEvents(for: character) else { return false }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3_000)  // Electron/web views drop characters that arrive in a single burst
        }
        return true
    }

    public static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard canPost("pressKey"), let (down, up) = keyEvents(keyCode, flags: flags) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Positive `lines` scroll up, negative scroll down. With `point`, the event targets the window under it
    /// instead of whatever is under the mouse pointer.
    public static func scroll(lines: Int, at point: CGPoint?) -> Bool {
        guard canPost("scroll"), let event = scrollEvent(lines: lines, at: point) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Hardware Play/Pause media key (system-defined NX_KEYTYPE_PLAY event), handled by the Now Playing app.
    public static func pressMediaPlayPause() -> Bool {
        guard canPost("pressMediaPlayPause") else { return false }
        for keyDown in [true, false] {
            guard let event = mediaKeyEvent(keyType: mediaKeyPlay, keyDown: keyDown) else { return false }
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: - Event construction (pure, testable without posting)

    static func clickEvents(at point: CGPoint) -> (move: CGEvent, down: CGEvent, up: CGEvent)? {
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return nil }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        return (move, down, up)
    }

    static func unicodeEvents(for character: Character) -> (CGEvent, CGEvent)? {
        let units = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return nil }
        // Held modifiers (e.g. the activation chord or a preceding ⌘A) must not turn text into shortcuts.
        down.flags = []
        up.flags = []
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
        }
        return (down, up)
    }

    static func keyEvents(_ keyCode: CGKeyCode, flags: CGEventFlags) -> (CGEvent, CGEvent)? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return nil }
        down.flags = flags
        up.flags = flags
        return (down, up)
    }

    static func scrollEvent(lines: Int, at point: CGPoint?) -> CGEvent? {
        let delta = Int32(clamping: lines)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
        else { return nil }
        if let point { event.location = point }
        return event
    }

    /// `data1` layout for NSSystemDefined subtype 8 (aux control buttons): key type in the high 16 bits,
    /// key state (0xA down / 0xB up) in bits 8-15.
    static func mediaKeyData1(keyType: Int, keyDown: Bool) -> Int {
        (keyType << 16) | ((keyDown ? 0xA : 0xB) << 8)
    }

    static func mediaKeyEvent(keyType: Int, keyDown: Bool) -> CGEvent? {
        NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: keyDown ? 0xA00 : 0xB00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: mediaKeyData1(keyType: keyType, keyDown: keyDown),
            data2: -1
        )?.cgEvent
    }

    private static func canPost(_ operation: String) -> Bool {
        guard AXIsProcessTrusted() else {
            Log.input.error("\(operation, privacy: .public) skipped: Accessibility permission not granted")
            return false
        }
        return true
    }
}
