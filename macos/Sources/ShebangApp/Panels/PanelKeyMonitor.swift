import AppKit

/// Keys the floating panels handle themselves: Esc, Return, and the standard editing shortcuts, which an agent app
/// without an active main menu would otherwise not deliver to text fields.
enum PanelKeyCommand: Equatable {
    enum EditAction: Equatable {
        case cut, copy, paste, selectAll, undo, redo

        var selector: Selector {
            switch self {
            case .cut: return #selector(NSText.cut(_:))
            case .copy: return #selector(NSText.copy(_:))
            case .paste: return #selector(NSText.paste(_:))
            case .selectAll: return #selector(NSText.selectAll(_:))
            case .undo: return Selector(("undo:"))
            case .redo: return Selector(("redo:"))
            }
        }
    }

    case cancel
    case confirm
    case edit(EditAction)

    static let escapeKeyCode: UInt16 = 0x35
    static let returnKeyCode: UInt16 = 0x24
    static let keypadEnterKeyCode: UInt16 = 0x4C

    static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> PanelKeyCommand? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        switch keyCode {
        case escapeKeyCode:
            return flags.isEmpty ? .cancel : nil
        case returnKeyCode, keypadEnterKeyCode:
            return flags.isEmpty ? .confirm : nil
        default:
            break
        }

        guard flags.contains(.command), flags.isDisjoint(with: [.control, .option]),
              let key = characters?.lowercased() else { return nil }
        let shifted = flags.contains(.shift)
        switch key {
        case "x" where !shifted: return .edit(.cut)
        case "c" where !shifted: return .edit(.copy)
        case "v" where !shifted: return .edit(.paste)
        case "a" where !shifted: return .edit(.selectAll)
        case "z": return .edit(shifted ? .redo : .undo)
        default: return nil
        }
    }
}

/// One local key-down monitor shared by the panels. Each panel registers a handler that returns true when it
/// consumed the key; events for other windows pass through untouched.
@MainActor
final class PanelKeyMonitor {
    typealias Handler = (PanelKeyCommand, NSEvent) -> Bool

    private var handlers: [ObjectIdentifier: Handler] = [:]
    private var monitor: Any?

    func register(_ window: NSWindow, handler: @escaping Handler) {
        handlers[ObjectIdentifier(window)] = handler
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Only the editing shortcuts (so an API key can be pasted); Esc and Return reach the window's own buttons.
    func registerEditingShortcuts(for window: NSWindow) {
        register(window) { [weak window] command, _ in
            guard case .edit(let action) = command, let window else { return false }
            return Self.perform(action, in: window)
        }
    }

    static func perform(_ action: PanelKeyCommand.EditAction, in window: NSWindow) -> Bool {
        window.firstResponder?.tryToPerform(action.selector, with: nil) ?? false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow,
              let handler = handlers[ObjectIdentifier(window)],
              let command = PanelKeyCommand.from(
                keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
        else { return false }
        return handler(command, event)
    }
}
