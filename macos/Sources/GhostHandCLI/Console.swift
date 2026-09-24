import Foundation

/// Serialized terminal output. The agent loop reports from its own task and the confirmation prompt reads
/// stdin on a helper thread, so every write takes a lock and flushes. Colors only when stdout is a TTY
/// and `NO_COLOR` is unset.
enum Console {
    enum Style: String {
        case bold = "1", dim = "2", red = "31", green = "32", yellow = "33", cyan = "36"
    }

    static let rule = String(repeating: "-", count: 80)

    private static let lock = NSLock()

    private static let colorEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return isatty(STDOUT_FILENO) == 1 && env["NO_COLOR"] == nil && env["TERM"] != "dumb"
    }()

    static func line(_ text: String = "", _ style: Style? = nil) {
        write(text + "\n", style)
    }

    /// Writes without a trailing newline (prompts, countdowns).
    static func write(_ text: String, _ style: Style? = nil) {
        let output = style.map { colorEnabled ? "\u{1B}[\($0.rawValue)m\(text)\u{1B}[0m" : text } ?? text
        lock.withLock {
            fputs(output, stdout)
            fflush(stdout)
        }
    }

    /// Usage errors go to stderr so scripts can tell them apart from command output.
    static func error(_ text: String) {
        lock.withLock {
            _ = fputs(text + "\n", stderr)
        }
    }

    /// Pads or truncates to exactly `width` characters (for table columns).
    static func column(_ text: String, _ width: Int) -> String {
        if text.count > width { return String(text.prefix(max(width - 3, 0))) + "..." }
        return text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// Collapses newlines and tabs so one element stays on one line.
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
    }
}
