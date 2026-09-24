import Foundation
import ShebangCore
import ShebangPlatform

/// `shebang run "<goal>"`: the full agent loop, wired like the app, with progress on stdout.
enum RunCommand {
    /// Windows CLI limits: short runs that stop quickly when the screen does not change.
    static let defaultMaxSteps = 10
    static let maxConsecutiveStalls = 3

    static func execute(_ arguments: RunArguments) async -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let loopOptions = makeLoopOptions(arguments, environment: environment)
        let isLive = !loopOptions.dryRun

        Console.line(isLive ? "Shebang Agent Loop: LIVE EXECUTION MODE" : "Shebang Agent Loop: DRY-RUN MODE", .bold)
        Console.line(Console.rule)
        Console.line("Goal: \"\(arguments.goal)\"")
        let steps = loopOptions.maxSteps > 0 ? "at most \(loopOptions.maxSteps) steps" : "no step limit"
        if isLive {
            Console.line("WARNING: LIVE mode sends real clicks and keystrokes (\(steps)). Press Ctrl-C to stop.\n", .yellow)
        } else {
            Console.line("Simulated mode: no clicks or keystrokes are sent (\(steps)). Use --live to execute.\n")
        }

        guard let apiKey = ResolvedAPIKey.resolve(environment: environment) else {
            Console.line("AI_GATEWAY_API_KEY is not configured; Jev cannot choose actions.", .red)
            Console.line(ResolvedAPIKey.missingKeyHelp)
            return 1
        }

        let tracker = FrontmostWindowTracker()
        guard var target = await TargetSelection.resolve(arguments.target, tracker: tracker) else { return 1 }

        if TargetSelection.looksLikeTerminal(target) {
            // Live keystrokes into the terminal running shebang would land in this process (or the shell).
            let refuse = isLive && (TargetSelection.isHostTerminal(target) || arguments.target == .frontmost)
            Console.line("[NOTE] Target '\(target.processName)' looks like the terminal running shebang.",
                         refuse ? .red : .yellow)
            if refuse {
                Console.line("Refusing a live run: keystrokes would go to this terminal. Switch to the target app", .red)
                Console.line("during the countdown, or use --target <app>.", .red)
                return 1
            }
            Console.line("If you meant another app, switch to it during the countdown or use --target <app>.\n", .yellow)
        }

        if case .query = arguments.target {
            Console.line("Found '\(target.processName)' (PID \(target.processId)). Bringing it to the front...")
            if !tracker.activate(target) {
                Console.line("Could not activate '\(target.processName)'; continuing with it in the background.", .yellow)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Activation can reveal or switch windows; describe what is actually in front now.
            target = tracker.target(forProcessID: target.processId) ?? target
        }
        TargetSelection.printTarget(target)
        Console.line("")

        if !Permissions.isAccessibilityTrusted {
            Console.line("[PERMISSION] Accessibility is not granted to this terminal: the accessibility tree cannot", .yellow)
            Console.line("be read and live input will not reach other apps. See 'shebang check'.\n", .yellow)
        }

        var jevOptions = JevOptions.fromEnvironment(environment)
        jevOptions.apiKey = apiKey.value
        let launcher = WorkspaceAppLauncher()
        launcher.preferredBrowserName = launcher.browserName(in: arguments.goal)
        let auditLog = JSONLAuditLog()

        let loop = AgentLoop(
            screenReader: AXScreenReader(),
            decisionModel: JevDecisionModel(client: JevClient(options: jevOptions), options: jevOptions),
            actionExecutor: MacActionExecutor(target: target, dryRun: loopOptions.dryRun, appLauncher: launcher),
            options: loopOptions,
            riskPolicy: DefaultRiskPolicy(),
            confirmationPrompt: ConsoleConfirmationPrompt(),
            auditLog: auditLog,
            windowTracker: tracker)

        loop.onStatus = { message in
            Console.line("[STATUS] \(message)", .yellow)
        }
        loop.onStepCompleted = { step, decision, result in
            let label = decision.targetLabel ?? decision.targetId ?? ""
            let confidence = Int((decision.confidence * 100).rounded())
            Console.line("[STEP \(step)] Decision: \(decision.operation.rawValue) on '\(label)' (Conf: \(confidence)%)", .green)
            let outcome = result.success ? "SUCCESS" : "FAIL"
            Console.line("         Action Result: \(outcome) - \(result.message ?? result.error ?? "")\n")
        }
        loop.onTargetChanged = { newTarget in
            Console.line("[TARGET] Now working in \(newTarget.processName) (\"\(newTarget.windowTitle)\")", .cyan)
        }

        let goal = arguments.goal
        let startTarget = target
        let run = Task.detached { await loop.run(goal: goal, target: startTarget) }
        let interrupt = InterruptHandler {
            Console.line("\n[KILL SWITCH] Interrupted by user. Cancelling... (Ctrl-C again quits immediately)", .red)
            run.cancel()
        }
        let result = await run.value
        interrupt.stop()

        Console.line(Console.rule)
        let style: Console.Style
        switch result.status {
        case .completed: style = .green
        case .needsHumanInput, .stalled, .maxStepsReached: style = .yellow
        case .cancelled, .failed: style = .red
        }
        Console.line("Result: \(statusName(result.status)) (\(result.stepsCompleted) steps)", style)
        Console.line("Message: \(result.message ?? "")", style)
        let auditFile = auditLog.fileURL(for: Date())
        let auditPath = FileManager.default.fileExists(atPath: auditFile.path) ? auditFile.path : auditLog.directory.path
        Console.line("Audit log: \(auditPath)", .dim)
        Console.line(Console.rule)
        return result.status == .completed ? 0 : 1
    }

    static func makeLoopOptions(_ arguments: RunArguments, environment: [String: String]) -> AgentLoopOptions {
        var options = AgentLoopOptions.fromEnvironment(environment)
        switch arguments.mode {
        case .environment: break
        case .dryRun: options.dryRun = true
        case .live: options.dryRun = false
        }
        if let maxSteps = arguments.maxSteps {
            options.maxSteps = maxSteps
        } else if Int(environment["MAX_STEPS_PER_RUN"]?.trimmingCharacters(in: .whitespaces) ?? "") == nil {
            options.maxSteps = defaultMaxSteps
        }
        options.maxConsecutiveStalls = maxConsecutiveStalls
        if arguments.confirmRisky {
            options.escalateOnModelRiskScore = .irreversibleOrExternalEffect
        }
        return options
    }

    /// `needsHumanInput` -> `NEEDS_HUMAN_INPUT`.
    static func statusName(_ status: AgentRunStatus) -> String {
        status.rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name += "_" }
            name += character.uppercased()
        }
    }
}

/// Turns the first Ctrl-C into a callback (cancelling the run) and a second one into an immediate exit.
final class InterruptHandler {
    private let source: DispatchSourceSignal
    private var interrupts = 0

    init(onInterrupt: @escaping () -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "com.shebang.cli.sigint"))
        source.setEventHandler { [unowned self] in
            interrupts += 1
            guard interrupts == 1 else {
                Console.line("\nQuitting.", .red)
                exit(130)
            }
            onInterrupt()
        }
        source.resume()
    }

    func stop() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
