import Foundation
import ShebangCore

/// Maps AX roles/subroles to `AccessibilityElement.role`. Raw `AX*` strings are kept (ElementRanker and the
/// decision model understand them); subroles only refine roles where they carry extra meaning.
enum AXRoleMapper {
    static func isSecure(role: String, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    static func elementRole(role: String, subrole: String?) -> String {
        switch (role, subrole) {
        case ("AXTextField", "AXSearchField"?): return "AXSearchField"
        case ("", _): return "AXUnknown"
        default: return role
        }
    }

    /// Layout-only nodes: never emitted, but their children are walked.
    static let structuralRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXScrollArea", "AXScrollBar", "AXSplitGroup",
        "AXSplitter", "AXLayoutArea", "AXLayoutItem", "AXGrowArea", "AXValueIndicator", "AXMatte", "AXRuler",
        "AXRulerMarker", "AXUnknown",
    ]

    /// Grouping nodes that are only emitted when they are labelled AND pressable (clickable web containers).
    static let containerRoles: Set<String> = [
        "AXGroup", "AXList", "AXTable", "AXOutline", "AXToolbar", "AXTabGroup", "AXRadioGroup", "AXBrowser",
        "AXColumn", "AXMenuBar", "AXMenu", "AXGrid", "AXSection", "AXLandmarkMain", "AXLandmarkNavigation",
    ]

    static let pressActions = ["AXPress", "AXConfirm", "AXOpen", "AXPick"]

    /// Whether `AXValue` should be fetched for a node with this role (skips layout/containers to save IPC).
    static func readsValue(role: String) -> Bool {
        !structuralRoles.contains(role) && !containerRoles.contains(role)
    }

    /// First non-empty of title, description, placeholder, help.
    static func label(for snapshot: AXNodeSnapshot) -> String {
        [snapshot.title, snapshot.description, snapshot.placeholder, snapshot.help]
            .lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Caps huge values (documents, text areas) before sanitizing. Cuts at a whitespace boundary so a
    /// secret straddling the limit is dropped rather than leaked as an unrecognisable fragment.
    static func truncated(_ text: String, limit: Int = 1000) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        if let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }) {
            return String(prefix[..<lastSpace]) + "…"
        }
        return "…"
    }
}
