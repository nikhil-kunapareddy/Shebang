import Foundation
import GhostHandCore
import GhostHandPlatform

/// `ghosthand read`: runs the same perception as the agent (`AXScreenReader` with OCR fallback) and prints
/// the ranked elements with the ids the decision model would see.
enum ReadCommand {
    static func execute(target selector: TargetSelector) async -> Int32 {
        Console.line("GhostHand Window Snapshot")
        Console.line(Console.rule)

        guard let target = await TargetSelection.resolve(selector, tracker: FrontmostWindowTracker()) else { return 1 }
        TargetSelection.printTarget(target)

        let accessibility = Permissions.isAccessibilityTrusted
        let screenRecording = Permissions.hasScreenRecording
        if !accessibility {
            Console.line("\n[PERMISSION] Accessibility is not granted to this terminal, so the accessibility tree", .yellow)
            Console.line("cannot be read\(screenRecording ? "; falling back to OCR" : "")." +
                         " Grant it in System Settings > Privacy & Security > Accessibility.", .yellow)
        }

        Console.line("\nReading the accessibility tree...")
        let start = Date()
        let elements: [AccessibilityElement]
        do {
            elements = try await AXScreenReader().readElements(target: target)
        } catch {
            Console.line("Snapshot failed: \(error.localizedDescription)", .red)
            return 1
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        Console.line("Completed in \(elapsedMs) ms | Found \(elements.count) elements", .green)
        guard !elements.isEmpty else {
            Console.line("No elements found.", .yellow)
            if target.windowNumber == 0 && target.windowBounds.isEmpty {
                Console.line("'\(target.processName)' has no open window to read. Open one and try again.")
            } else if !accessibility {
                Console.line("Grant Accessibility (and optionally Screen Recording for OCR) to your terminal app.")
            } else if !screenRecording {
                Console.line("The app exposed no usable controls; Screen Recording enables the OCR fallback.")
            }
            return 1
        }

        let ocrCount = elements.filter { $0.source == "ocr" }.count
        let interactiveCount = elements.filter { ElementRanker.isInteractive($0.role) }.count
        Console.line("Interactive controls: \(interactiveCount) | OCR elements: \(ocrCount)")
        Console.line(Console.rule)
        Console.line(row(id: "ID", role: "ROLE", state: "STATE", source: "SRC", frame: "FRAME", text: "LABEL / VALUE"))
        Console.line(Console.rule)
        for element in elements {
            let style: Console.Style? = element.focused
                ? .yellow
                : (ElementRanker.isInteractive(element.role) ? .cyan : nil)
            Console.line(row(
                id: element.id,
                role: element.displayRole,
                state: element.focused ? "[FOCUSED]" : (element.enabled ? "Enabled" : "Disabled"),
                source: element.source == "ocr" ? "ocr" : "ax",
                frame: describe(element.frame),
                text: labelAndValue(element)), style)
        }
        Console.line(Console.rule)
        Console.line("SRC: ax = Accessibility API, ocr = Vision text recognition. Secure text fields are never read.",
                     .dim)
        return 0
    }

    private static func row(id: String, role: String, state: String, source: String, frame: String, text: String) -> String {
        [Console.column(id, 5), Console.column(role, 16), Console.column(state, 9), Console.column(source, 3),
         Console.column(frame, 22), text].joined(separator: " ")
    }

    private static func describe(_ frame: CGRect) -> String {
        guard !frame.isEmpty else { return "-" }
        return "(\(Int(frame.minX)),\(Int(frame.minY))) \(Int(frame.width))x\(Int(frame.height))"
    }

    private static func labelAndValue(_ element: AccessibilityElement) -> String {
        let label = truncate(Console.singleLine(element.label.trimmingCharacters(in: .whitespacesAndNewlines)), 60)
        let value = truncate(Console.singleLine(element.value.trimmingCharacters(in: .whitespacesAndNewlines)), 40)
        switch (label.isEmpty, value.isEmpty || value == label) {
        case (true, true): return "(empty)"
        case (true, false): return "= \"\(value)\""
        case (false, true): return label
        case (false, false): return "\(label) = \"\(value)\""
        }
    }

    private static func truncate(_ text: String, _ maxLength: Int) -> String {
        text.count > maxLength ? String(text.prefix(maxLength - 3)) + "..." : text
    }
}
