import Foundation
import GhostHandCore

enum TextEntryHeuristics {
    static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]

    /// In terminals ⌘A selects the scrollback, so the prompt is cleared with readline's ⌃A ⌃K instead.
    static func isTerminal(_ bundleIdentifier: String) -> Bool {
        terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    private static let searchKeywords = ["address", "search", "omnibox", "url", "find", "google", "query", "bar"]

    /// Port of `IsSearchOrAddressBar`: text typed into these is submitted with Return automatically.
    static func isSearchOrAddressBar(_ element: AccessibilityElement?) -> Bool {
        guard let element else { return false }
        if element.role.caseInsensitiveCompare("AXSearchField") == .orderedSame { return true }
        let label = element.displayLabel.lowercased()
        return searchKeywords.contains { label.contains($0) }
    }

    /// Multi-line roles (Notes body, Mail compose, TextEdit, web `<textarea>`).
    static func isMultiline(role: String) -> Bool {
        ["axtextarea", "textarea", "document"].contains(role.lowercased())
    }

    /// Documents get text appended at the end: replacing their value or select-all + delete would destroy them.
    /// Search boxes that happen to be text areas (e.g. YouTube's) keep replace semantics so queries never pile up.
    static func isDocument(_ element: AccessibilityElement) -> Bool {
        isMultiline(role: element.role) && !isSearchOrAddressBar(element)
    }

    /// Whether a document already ends with `text` (a repeated TypeText after a successful one).
    static func alreadyEndsWith(_ current: String?, _ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current, !trimmedText.isEmpty else { return false }
        return current.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(trimmedText)
    }

    /// Secure/password fields: typed text must never be logged or echoed in results.
    static func isSecure(role: String, subrole: String? = nil) -> Bool {
        let lowered = role.lowercased()
        return AXRoleMapper.isSecure(role: role, subrole: subrole) || lowered.contains("secure") || lowered.contains("password")
    }
}
