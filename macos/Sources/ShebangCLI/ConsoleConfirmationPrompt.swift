import Foundation
import ShebangCore

/// Asks for approval of a risky action on the terminal (`run --confirm-risky`).
/// Anything but `y`/`yes` rejects, as do end of input and a cancelled run.
final class ConsoleConfirmationPrompt: ConfirmationPrompt {
    func requestConfirmation(
        decision: AgentDecision,
        target: AccessibilityElement?,
        app: AppTarget,
        reason: String
    ) async -> Bool {
        let banner = String(repeating: "=", count: 80)
        Console.line("\n" + banner, .yellow)
        Console.line(String(repeating: " ", count: 26) + "SAFETY CONFIRMATION REQUIRED", .yellow)
        Console.line(banner, .yellow)

        let targetLabel = target.map(\.displayLabel).flatMap { $0.isEmpty ? nil : $0 }
            ?? decision.targetLabel ?? decision.targetId ?? "(none)"
        Console.line("Action:     \(decision.operation.rawValue)")
        Console.line("Target:     \(targetLabel) (\(target?.displayRole ?? "Control"))")
        if let text = decision.textValue, !text.isEmpty {
            Console.line("Value:      \"\(text)\"")
        }
        Console.line("App:        \(app.processName) - \"\(app.windowTitle)\"")
        Console.line("Reason:     \(reason)", .red)
        Console.line(Console.rule)

        Console.write("Do you approve executing this action? [y/N] (default: N): ", .cyan)
        guard let input = await StandardInput.readLine() else {
            Console.line("\nNo answer (input closed or run cancelled). Action REJECTED.\n")
            return false
        }
        let answer = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let approved = answer == "y" || answer == "yes"
        Console.line(approved ? "Action APPROVED by human.\n" : "Action REJECTED by human.\n")
        return approved
    }
}
