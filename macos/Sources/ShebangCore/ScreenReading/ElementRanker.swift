import Foundation

public enum ElementRanker {
    /// AX roles, compared without the `AX` prefix.
    private static let interactiveRoles: Set<String> = [
        "button", "menuitem", "menubaritem", "link", "checkbox",
        "radiobutton", "combobox", "popupbutton", "menubutton",
        "textfield", "textarea", "searchfield", "slider",
        "disclosuretriangle", "incrementor",
    ]

    public static func rankAndFilter(_ elements: [AccessibilityElement], options: ScreenReaderOptions) -> [AccessibilityElement] {
        let filtered = elements
            .filter { !options.filterOffscreen || isOnScreen($0) }
            .filter { !options.filterDisabled || $0.enabled }
            .prefix(options.maxNodes)

        // Priority: focused, interactive, labelled, outcome evidence, then visual order.
        // The enumerated index keeps the sort stable: ties keep their input order.
        let sorted = filtered.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            if a.focused != b.focused { return a.focused }
            let aInteractive = isInteractive(a.role), bInteractive = isInteractive(b.role)
            if aInteractive != bInteractive { return aInteractive }
            let aLabelled = !a.displayLabel.isEmpty, bLabelled = !b.displayLabel.isEmpty
            if aLabelled != bLabelled { return aLabelled }
            if a.isOutcomeEvidence != b.isOutcomeEvidence { return a.isOutcomeEvidence }
            if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            return lhs.offset < rhs.offset
        }

        // Assign sequential ids e1, e2, ... to the capped candidate list.
        return sorted.prefix(options.maxCandidates).enumerated().map { index, pair in
            var element = pair.element
            element.id = "e\(index + 1)"
            return element
        }
    }

    public static func isInteractive(_ role: String) -> Bool {
        let lowered = role.lowercased()
        return interactiveRoles.contains(lowered)
            || (lowered.hasPrefix("ax") && interactiveRoles.contains(String(lowered.dropFirst(2))))
    }

    private static func isOnScreen(_ element: AccessibilityElement) -> Bool {
        element.frame.width > 0 && element.frame.height > 0
    }
}
