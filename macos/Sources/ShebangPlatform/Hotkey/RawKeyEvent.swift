import Foundation

/// A raw keyboard event received from the event tap.
/// Key codes are macOS virtual key codes (`kVK_*` from Carbon's Events.h).
public struct RawKeyEvent: Sendable, Equatable {
    public static let vkControl: UInt16 = 0x3B
    public static let vkRightControl: UInt16 = 0x3E
    public static let vkCommand: UInt16 = 0x37
    public static let vkRightCommand: UInt16 = 0x36
    public static let vkEscape: UInt16 = 0x35

    static let vkShift: UInt16 = 0x38
    static let vkRightShift: UInt16 = 0x3C
    static let vkOption: UInt16 = 0x3A
    static let vkRightOption: UInt16 = 0x3D
    static let vkCapsLock: UInt16 = 0x39
    static let vkFunction: UInt16 = 0x3F

    public var keyCode: UInt16
    public var isKeyUp: Bool
    /// Synthesized by Shebang itself (e.g. the executor pressing Escape); ignored by the chord machine.
    public var isInjected: Bool

    public init(keyCode: UInt16, isKeyUp: Bool, isInjected: Bool = false) {
        self.keyCode = keyCode
        self.isKeyUp = isKeyUp
        self.isInjected = isInjected
    }

    public var isControl: Bool { keyCode == Self.vkControl || keyCode == Self.vkRightControl }
    public var isCommand: Bool { keyCode == Self.vkCommand || keyCode == Self.vkRightCommand }
}

extension RawKeyEvent {
    // Device-dependent modifier bits (IOLLEvent.h NX_DEVICE*KEYMASK) and generic CGEventFlags bits.
    static let deviceLeftControl: UInt64 = 0x0000_0001
    static let deviceRightControl: UInt64 = 0x0000_2000
    static let deviceLeftCommand: UInt64 = 0x0000_0008
    static let deviceRightCommand: UInt64 = 0x0000_0010
    static let flagAlphaShift: UInt64 = 0x0001_0000
    static let flagShift: UInt64 = 0x0002_0000
    static let flagControl: UInt64 = 0x0004_0000
    static let flagAlternate: UInt64 = 0x0008_0000
    static let flagCommand: UInt64 = 0x0010_0000
    static let flagSecondaryFn: UInt64 = 0x0080_0000

    /// Modifier keys arrive as `flagsChanged` events rather than key down/up. Translates one into a
    /// down/up event for the key that changed, or nil for key codes that are not modifiers.
    static func fromFlagsChanged(keyCode: UInt16, flags: UInt64, isInjected: Bool = false) -> RawKeyEvent? {
        func sidedIsDown(own: UInt64, other: UInt64, generic: UInt64) -> Bool {
            if flags & own != 0 { return true }
            // Some keyboards don't report device-dependent bits; fall back to the generic flag.
            return flags & (own | other) == 0 && flags & generic != 0
        }

        let isDown: Bool
        switch keyCode {
        case vkControl:
            isDown = sidedIsDown(own: deviceLeftControl, other: deviceRightControl, generic: flagControl)
        case vkRightControl:
            isDown = sidedIsDown(own: deviceRightControl, other: deviceLeftControl, generic: flagControl)
        case vkCommand:
            isDown = sidedIsDown(own: deviceLeftCommand, other: deviceRightCommand, generic: flagCommand)
        case vkRightCommand:
            isDown = sidedIsDown(own: deviceRightCommand, other: deviceLeftCommand, generic: flagCommand)
        case vkShift, vkRightShift:
            isDown = flags & flagShift != 0
        case vkOption, vkRightOption:
            isDown = flags & flagAlternate != 0
        case vkCapsLock:
            isDown = flags & flagAlphaShift != 0
        case vkFunction:
            isDown = flags & flagSecondaryFn != 0
        default:
            return nil
        }
        return RawKeyEvent(keyCode: keyCode, isKeyUp: !isDown, isInjected: isInjected)
    }
}
