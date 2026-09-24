import Foundation
import ShebangCore

enum TextEntryHeuristics {
    static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]

    /// In terminals ⌘A selects the scrollback, so the prompt is cleared with readline's ⌃A ⌃K instead.
    static func isTerminal(_ bundleIdentifier: String) -> Bool {
        terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    private static let searchKeywords: Set<String> = ["address", "search", "omnibox", "url", "find", "google", "query", "bar"]

    /// Port of `IsSearchOrAddressBar`: text typed into these is submitted with Return automatically.
    /// Only the control's own label counts, as whole words. `displayLabel` would fall back to the value,
    /// turning a document that mentions "find" into a search box that gets replaced and submitted.
    static func isSearchOrAddressBar(_ element: AccessibilityElement?) -> Bool {
        guard let element else { return false }
        if element.role.caseInsensitiveCompare("AXSearchField") == .orderedSame { return true }
        let words = element.label.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.contains { searchKeywords.contains(String($0)) }
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
