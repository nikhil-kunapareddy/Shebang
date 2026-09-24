import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Finds the physical key that types a character in the user's layout. `kVK_ANSI_*` codes are key
/// positions, so a hardcoded ⌘ + kVK_ANSI_A is ⌘Q on AZERTY and would quit the target app.
enum KeyboardLayout {
    /// Key code producing `character` in the current ASCII-capable layout (the one macOS uses to match
    /// ⌘ shortcuts, even while a non-Latin layout is active), or nil when no key produces it.
    static func keyCode(for character: Character) -> CGKeyCode? {
        // Text Input Sources must be queried on the main thread.
        Thread.isMainThread ? lookup(character) : DispatchQueue.main.sync { lookup(character) }
    }

    private static func lookup(_ character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let wanted = String(character).lowercased()

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<CGKeyCode(128) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == wanted {
                    return code
                }
            }
            return nil
        }
    }
}
