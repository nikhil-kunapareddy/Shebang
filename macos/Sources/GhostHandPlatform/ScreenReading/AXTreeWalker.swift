import ApplicationServices
import CoreGraphics
import Foundation
import GhostHandCore

/// Bounded pre-order walk of an AX subtree (document order, like UIA `FindAllDescendants`).
/// Limits: `maxDepth`, `maxNodes` emitted elements, `visitLimit` visited nodes, a wall-clock budget,
/// and an early stop when the app stops answering.
struct AXTreeWalker {
    struct Result {
        var elements: [AccessibilityElement] = []
        /// Parallel to `elements`.
        var handles: [AXUIElement] = []
        var visited = 0
        var skippedSecure = 0
        var stopReason: String?
    }

    let backend: AXBackend
    let options: ScreenReaderOptions
    var visitLimit: Int
    var timeBudget: TimeInterval = 2.0
    var maxTimeouts = 3

    init(backend: AXBackend, options: ScreenReaderOptions) {
        self.backend = backend
        self.options = options
        // Web and Electron trees hide controls under many unlabelled groups, so visit more than we emit.
        self.visitLimit = max(options.maxNodes, 1) * 6
    }

    /// `clipFrame` is the window frame; controls entirely outside it are scrolled out of view.
    func walk(root: AXUIElement, clipFrame: CGRect?) throws -> Result {
        var result = Result()
        var stack: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        // Emitted-but-unlabelled interactive ancestors of the current node; filled from descendant text.
        var unlabelled: [(index: Int, depth: Int)] = []
        let deadline = Date().addingTimeInterval(timeBudget)
        var timeouts = 0

        walking: while let (element, depth) = stack.popLast() {
            if result.visited % 32 == 0 { try Task.checkCancellation() }
            if result.elements.count >= options.maxNodes { result.stopReason = "maxNodes"; break }
            if result.visited >= visitLimit { result.stopReason = "visitLimit"; break }
            if Date() >= deadline { result.stopReason = "timeBudget"; break }
            result.visited += 1

            let snapshot: AXNodeSnapshot
            switch backend.snapshot(of: element) {
            case .node(let node):
                snapshot = node
            case .unavailable:
                continue walking
            case .timedOut:
                timeouts += 1
                if depth == 0 || timeouts >= maxTimeouts { result.stopReason = "unresponsive"; break walking }
                continue walking
            }

            // Secure text fields are dropped with their subtree before any value is requested.
            if AXRoleMapper.isSecure(role: snapshot.role, subrole: snapshot.subrole) {
                result.skippedSecure += 1
                continue walking
            }

            while let last = unlabelled.last, last.depth >= depth { unlabelled.removeLast() }

            if let extracted = extract(element, snapshot: snapshot, clipFrame: clipFrame) {
                if extracted.role == "AXStaticText", !extracted.value.isEmpty, !unlabelled.isEmpty {
                    for pending in unlabelled { result.elements[pending.index].label = extracted.value }
                    unlabelled.removeAll()
                }
                result.elements.append(extracted)
                result.handles.append(element)
                if extracted.label.isEmpty, extracted.value.isEmpty {
                    unlabelled.append((result.elements.count - 1, depth))
                }
            }

            if depth + 1 < options.maxDepth {
                for child in snapshot.children.reversed() { stack.append((child, depth + 1)) }
            }
        }
        return result
    }

    private func extract(_ handle: AXUIElement, snapshot: AXNodeSnapshot, clipFrame: CGRect?) -> AccessibilityElement? {
        guard !AXRoleMapper.structuralRoles.contains(snapshot.role) else { return nil }
        let role = AXRoleMapper.elementRole(role: snapshot.role, subrole: snapshot.subrole)

        let frame = snapshot.frame ?? .zero
        if options.filterOffscreen, let clipFrame, !clipFrame.isEmpty,
           frame.width > 0, frame.height > 0, !clipFrame.intersects(frame) {
            return nil
        }

        let label = SecretSanitizer.sanitize(AXRoleMapper.truncated(AXRoleMapper.label(for: snapshot)))
        let isContainer = AXRoleMapper.containerRoles.contains(snapshot.role)
        if isContainer && label.isEmpty { return nil }

        let rawValue = AXRoleMapper.readsValue(role: snapshot.role) ? backend.value(of: handle) : nil
        let value = SecretSanitizer.sanitize(rawValue.map { AXRoleMapper.truncated($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if label.isEmpty && value.isEmpty && !ElementRanker.isInteractive(role) { return nil }

        let actions = backend.actionNames(of: handle)
        if isContainer && !actions.contains("AXPress") { return nil }

        return AccessibilityElement(
            id: "",
            role: role,
            label: label,
            value: value,
            enabled: snapshot.enabled,
            focused: snapshot.focused,
            frame: frame,
            source: "accessibility",
            actions: actions
        )
    }
}
