import Foundation

/// Confirms keyboard focus before typing. Tree snapshots may omit AXFocused and composite fields can give
/// focus to an inner editor, so the app's focused element is queried directly (ported from the original app).
enum TextFieldFocus {
    enum Failure: String, Error, LocalizedError {
        case unavailable = "field_focus_unconfirmed"
        case changed = "field_focus_changed"

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The selected text field did not report keyboard focus after waiting. No text was entered."
            case .changed: return "Keyboard focus left the selected text field. Text entry was stopped."
            }
        }
    }

    typealias Sleep = (TimeInterval) async throws -> Void

    static let taskSleep: Sleep = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Whether `focused` is `target` or one of its descendants (bounded against cyclic parent chains).
    static func contains<Node>(_ focused: Node, target: Node, equal: (Node, Node) -> Bool, parent: (Node) -> Node?) -> Bool {
        var current: Node? = focused
        for _ in 0..<32 {
            guard let node = current else { return false }
            if equal(node, target) { return true }
            current = parent(node)
        }
        return false
    }

    /// An already-focused field needs no click. Requests AX focus before falling back to a mouse click,
    /// and a click alone never authorizes typing: focus must be confirmed afterwards.
    static func prepare(
        attempts: Int = 11,
        interval: TimeInterval = 0.1,
        sleep: Sleep = taskSleep,
        check: () throws -> Void,
        probe: () async throws -> Bool,
        requestFocus: () throws -> Void,
        click: () throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try check()
        let alreadyFocused = try await probe()
        try Task.checkCancellation()
        try check()
        if alreadyFocused { return }
        try requestFocus()
        do {
            try await wait(attempts: attempts, interval: interval, sleep: sleep, check: check, probe: probe)
            return
        } catch Failure.unavailable {
            // Only a focus timeout warrants a click; cancellation and app changes propagate.
        }
        try check()
        try click()
        try await wait(attempts: attempts, interval: interval, sleep: sleep, check: check, probe: probe)
    }

    static func wait(
        attempts: Int = 11,
        interval: TimeInterval = 0.1,
        sleep: Sleep = taskSleep,
        check: () throws -> Void,
        probe: () async throws -> Bool
    ) async throws {
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            try check()
            let focused = try await probe()
            try Task.checkCancellation()
            try check()
            if focused { return }
            if attempt + 1 < attempts { try await sleep(interval) }
        }
        throw Failure.unavailable
    }
}
