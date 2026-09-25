import ApplicationServices
import CoreGraphics
import Foundation
import ShebangCore

/// Attributes of one AX node, fetched in a single batched round trip. Deliberately excludes `AXValue`,
/// which is read separately so secure text fields are never asked for their contents.
struct AXNodeSnapshot {
    var role: String
    var subrole: String?
    var title: String?
    var description: String?
    var placeholder: String?
    var help: String?
    var enabled: Bool
    var focused: Bool
    var frame: CGRect?
    var children: [AXUIElement]

    init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        placeholder: String? = nil,
        help: String? = nil,
        enabled: Bool = true,
        focused: Bool = false,
        frame: CGRect? = nil,
        children: [AXUIElement] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.description = description
        self.placeholder = placeholder
        self.help = help
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.children = children
    }
}

enum AXReadResult {
    case node(AXNodeSnapshot)
    /// Element vanished, attribute unsupported, or Accessibility permission missing.
    case unavailable
    /// The app did not answer within the messaging timeout (hung or busy).
    case timedOut
}

/// Seam over the Accessibility C API so reader and executor logic can be tested without TCC
/// permissions or a GUI session. Every call must return promptly (bounded by the messaging timeout).
protocol AXBackend: AnyObject {
    var isTrusted: Bool { get }
    func applicationElement(pid: Int32) -> AXUIElement
    func focusedWindow(of app: AXUIElement) -> AXUIElement?
    /// Focused window, else main window, else the first window.
    func windowRoot(of app: AXUIElement) -> AXUIElement?
    func snapshot(of element: AXUIElement) -> AXReadResult
    func value(of element: AXUIElement) -> String?
    func actionNames(of element: AXUIElement) -> [String]
    func roleAndSubrole(of element: AXUIElement) -> (role: String, subrole: String?)?
    func frame(of element: AXUIElement) -> CGRect?
    func isFocused(_ element: AXUIElement) -> Bool?
    func processID(of element: AXUIElement) -> Int32?
    func focusedElement(of app: AXUIElement) -> AXUIElement?
    func parent(of element: AXUIElement) -> AXUIElement?
    func element(at point: CGPoint, in app: AXUIElement) -> AXUIElement?
    func isValueSettable(_ element: AXUIElement) -> Bool
    @discardableResult func performAction(_ action: String, on element: AXUIElement) -> Bool
    @discardableResult func setValue(_ value: String, on element: AXUIElement) -> Bool
    @discardableResult func setBool(_ attribute: String, _ value: Bool, on element: AXUIElement) -> Bool
}

/// Pure decoding helpers for AX attribute values.
enum AXDecoding {
    static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// AX positions are global, top-left origin points — the same space CGEvent uses.
    static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let origin = point(position), let size = self.size(size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func string(_ value: AnyObject?) -> String? {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    static func stringOrNumber(_ value: AnyObject?) -> String? {
        if let string = string(value) { return string }
        // CFBoolean bridges to NSNumber too; checkboxes report 0/1.
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ value: AnyObject?) -> [AXUIElement] {
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap(element)
    }
}

/// Real Accessibility API calls. Every element gets a short messaging timeout before it is queried
/// so a hung target app costs at most `messagingTimeout` per call instead of the 6 s system default.
final class LiveAXBackend: AXBackend, @unchecked Sendable {
    static let shared = LiveAXBackend()

    let messagingTimeout: Float = 0.5

    var isTrusted: Bool { AXIsProcessTrusted() }

    private static let snapshotAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        "AXPlaceholderValue", kAXHelpAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ]

    private func prepared(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private func copy(_ attribute: String, of element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(prepared(element), attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func applicationElement(pid: Int32) -> AXUIElement {
        prepared(AXUIElementCreateApplication(pid))
    }

    func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        AXDecoding.element(copy(kAXFocusedWindowAttribute, of: app))
    }

    func windowRoot(of app: AXUIElement) -> AXUIElement? {
        focusedWindow(of: app)
            ?? AXDecoding.element(copy(kAXMainWindowAttribute, of: app))
            ?? AXDecoding.elements(copy(kAXWindowsAttribute, of: app)).first
    }

    func snapshot(of element: AXUIElement) -> AXReadResult {
        let keys = Self.snapshotAttributes
        var batch: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(prepared(element), keys as CFArray, [], &batch)
        switch error {
        case .success: break
        case .cannotComplete: return .timedOut
        default: return .unavailable
        }
        // Failed attributes come back as AXValue error placeholders, which the casts below reject.
        guard let values = batch as? [AnyObject], values.count == keys.count else { return .unavailable }
        func value(_ key: String) -> AnyObject? { values[keys.firstIndex(of: key)!] }
        guard let role = AXDecoding.string(value(kAXRoleAttribute)) else { return .unavailable }
        return .node(AXNodeSnapshot(
            role: role,
            subrole: AXDecoding.string(value(kAXSubroleAttribute)),
            title: AXDecoding.string(value(kAXTitleAttribute)),
            description: AXDecoding.string(value(kAXDescriptionAttribute)),
            placeholder: AXDecoding.string(value("AXPlaceholderValue")),
            help: AXDecoding.string(value(kAXHelpAttribute)),
            enabled: (value(kAXEnabledAttribute) as? Bool) ?? true,
            focused: (value(kAXFocusedAttribute) as? Bool) ?? false,
            frame: AXDecoding.frame(position: value(kAXPositionAttribute), size: value(kAXSizeAttribute)),
            children: AXDecoding.elements(value(kAXChildrenAttribute))
        ))
    }

    func value(of element: AXUIElement) -> String? {
        AXDecoding.stringOrNumber(copy(kAXValueAttribute, of: element))
    }

    func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(prepared(element), &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func roleAndSubrole(of element: AXUIElement) -> (role: String, subrole: String?)? {
        guard let role = AXDecoding.string(copy(kAXRoleAttribute, of: element)) else { return nil }
        return (role, AXDecoding.string(copy(kAXSubroleAttribute, of: element)))
    }

    func frame(of element: AXUIElement) -> CGRect? {
        AXDecoding.frame(position: copy(kAXPositionAttribute, of: element), size: copy(kAXSizeAttribute, of: element))
    }

    func isFocused(_ element: AXUIElement) -> Bool? {
        copy(kAXFocusedAttribute, of: element) as? Bool
    }

    func processID(of element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    func focusedElement(of app: AXUIElement) -> AXUIElement? {
        AXDecoding.element(copy(kAXFocusedUIElementAttribute, of: app))
    }

    func parent(of element: AXUIElement) -> AXUIElement? {
        AXDecoding.element(copy(kAXParentAttribute, of: element))
    }

    func element(at point: CGPoint, in app: AXUIElement) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(prepared(app), Float(point.x), Float(point.y), &hit) == .success else {
            return nil
        }
        return hit
    }

    func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(prepared(element), kAXValueAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    func performAction(_ action: String, on element: AXUIElement) -> Bool {
        AXUIElementPerformAction(prepared(element), action as CFString) == .success
    }

    func setValue(_ value: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(prepared(element), kAXValueAttribute as CFString, value as CFString) == .success
    }

    func setBool(_ attribute: String, _ value: Bool, on element: AXUIElement) -> Bool {
        let flag: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(prepared(element), attribute as CFString, flag) == .success
    }
}
