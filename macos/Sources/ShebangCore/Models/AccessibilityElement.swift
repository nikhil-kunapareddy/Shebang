import CoreGraphics
import Foundation

/// Platform-independent representation of a readable UI control or OCR detection on screen.
public struct AccessibilityElement: Sendable, Equatable, Codable {
    public var id: String
    /// Raw accessibility role, e.g. `AXButton`, `AXTextField`, or `OCRText` for OCR detections.
    public var role: String
    public var label: String
    public var value: String
    public var enabled: Bool
    public var focused: Bool
    /// Frame in global screen coordinates (top-left origin, as reported by the Accessibility API).
    public var frame: CGRect
    /// `"accessibility"` or `"ocr"`.
    public var source: String
    /// Supported AX actions, e.g. `AXPress`, `AXConfirm`.
    public var actions: [String]

    public init(
        id: String,
        role: String,
        label: String = "",
        value: String = "",
        enabled: Bool = true,
        focused: Bool = false,
        frame: CGRect = .zero,
        source: String = "accessibility",
        actions: [String] = []
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.source = source
        self.actions = actions
    }

    /// Role without the `AX` prefix (`AXButton` -> `Button`).
    public var displayRole: String {
        role.lowercased().hasPrefix("ax") ? String(role.dropFirst(2)) : role
    }

    public var displayLabel: String {
        if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return label }
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        return ""
    }

    public var isOutcomeEvidence: Bool {
        ["statictext", "axstatictext"].contains(role.lowercased())
    }
}
