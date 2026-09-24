import Foundation
import ShebangCore

/// One line of user-facing status text and how prominently to show it.
struct StatusLine: Equatable {
    enum Tone: Equatable {
        case neutral, info, success, warning, error, listening
    }

    var text: String
    var tone: Tone

    static func neutral(_ text: String) -> StatusLine { StatusLine(text: text, tone: .neutral) }
    static func info(_ text: String) -> StatusLine { StatusLine(text: text, tone: .info) }
    static func success(_ text: String) -> StatusLine { StatusLine(text: text, tone: .success) }
    static func warning(_ text: String) -> StatusLine { StatusLine(text: text, tone: .warning) }
    static func error(_ text: String) -> StatusLine { StatusLine(text: text, tone: .error) }
    static func listening(_ text: String) -> StatusLine { StatusLine(text: text, tone: .listening) }
}

/// How targets are described in the prompt, HUD, and confirmation panel.
enum TargetFormatting {
    /// `Target: Safari — “Apple”`, or just the app name when the title is empty or repeats it.
    static func promptDescription(_ target: AppTarget?) -> String {
        guard let target else { return "Target: Desktop" }
        return "Target: " + appDescription(target)
    }

    /// `Safari — “Apple”`, or just the app name when the title is empty or repeats it.
    static func appDescription(_ target: AppTarget) -> String {
        let title = target.windowTitle.trimmed
        guard !title.isEmpty, title != target.processName else { return target.processName }
        return "\(target.processName) — “\(title)”"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `nil` when the string is empty after trimming.
    var nonBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
