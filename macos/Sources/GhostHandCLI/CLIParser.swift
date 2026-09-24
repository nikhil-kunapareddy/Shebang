import Foundation

/// Which app a command works on.
enum TargetSelector: Equatable {
    /// Count down, then capture the frontmost app.
    case frontmost
    /// App name, bundle identifier, or pid from `--target` (or `read <app>`).
    case query(String)
}

enum ExecutionMode: Equatable {
    /// `DRY_RUN` from the environment / `.env` decides (dry-run when unset).
    case environment
    case dryRun
    case live
}

struct RunArguments: Equatable {
    var goal: String
    var target: TargetSelector = .frontmost
    var mode: ExecutionMode = .environment
    /// `nil` keeps `MAX_STEPS_PER_RUN`, else the CLI default.
    var maxSteps: Int?
    var confirmRisky = false
}

enum CLICommand: Equatable {
    case help
    case version
    case check
    case read(target: TargetSelector)
    case run(RunArguments)
}

struct UsageError: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Hand-rolled argument parsing. Commands and options are case-insensitive, like the Windows CLI;
/// `--name=value` is accepted and `--` ends option parsing (for goals that start with `-`).
enum CLIParser {
    private enum Option {
        case target, mode, maxSteps, confirmRisky
    }

    private struct Scanned {
        var positionals: [String] = []
        var target: String?
        var mode: ExecutionMode = .environment
        var maxSteps: Int?
        var confirmRisky = false
        var wantsHelp = false
    }

    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let first = arguments.first else { return .help }
        let command = first.lowercased()
        let rest = Array(arguments.dropFirst())

        switch command {
        case "help", "-h", "--help":
            return .help

        case "version", "--version":
            return .version

        case "check":
            let scanned = try scan(rest, command: command, allowed: [])
            if scanned.wantsHelp { return .help }
            guard scanned.positionals.isEmpty else {
                throw UsageError("'check' takes no arguments (got '\(scanned.positionals[0])').")
            }
            return .check

        case "read", "snapshot":
            let scanned = try scan(rest, command: command, allowed: [.target])
            if scanned.wantsHelp { return .help }
            // The Windows `snapshot <name|pid>` took the target positionally; both forms work.
            guard scanned.positionals.count <= 1, scanned.positionals.isEmpty || scanned.target == nil else {
                throw UsageError("'\(command)' takes a single target: ghosthand read [--target] <app|bundle-id|pid>")
            }
            let query = scanned.target ?? scanned.positionals.first
            return .read(target: query.map(TargetSelector.query) ?? .frontmost)

        case "run", "dry-run":
            let scanned = try scan(rest, command: command, allowed: [.target, .mode, .maxSteps, .confirmRisky])
            if scanned.wantsHelp { return .help }
            var mode = scanned.mode
            if command == "dry-run" {
                guard mode != .live else { throw UsageError("'dry-run' cannot be combined with --live.") }
                mode = .dryRun
            }
            let goal = scanned.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !goal.isEmpty else {
                throw UsageError("'\(command)' needs a goal, e.g. ghosthand \(command) \"search for Adele\"")
            }
            return .run(RunArguments(
                goal: goal,
                target: scanned.target.map(TargetSelector.query) ?? .frontmost,
                mode: mode,
                maxSteps: scanned.maxSteps,
                confirmRisky: scanned.confirmRisky))

        default:
            throw UsageError("Unknown command: '\(first)'")
        }
    }

    private static func scan(_ arguments: [String], command: String, allowed: Set<Option>) throws -> Scanned {
        var scanned = Scanned()
        var index = 0
        var optionsEnded = false

        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                scanned.positionals.append(argument)
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }

            var name = argument.lowercased()
            var inlineValue: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                name = argument[..<equals].lowercased()
                inlineValue = String(argument[argument.index(after: equals)...])
            }

            func requireAllowed(_ option: Option) throws {
                guard allowed.contains(option) else {
                    throw UsageError("Option '\(name)' is not valid for '\(command)'.")
                }
            }
            func noValue() throws {
                guard inlineValue == nil else { throw UsageError("Option '\(name)' does not take a value.") }
            }
            func value() throws -> String {
                if let inlineValue { return inlineValue }
                guard index < arguments.count else { throw UsageError("Option '\(name)' needs a value.") }
                index += 1
                return arguments[index - 1]
            }

            switch name {
            case "-h", "--help":
                try noValue()
                scanned.wantsHelp = true

            case "-t", "--target", "--process":
                try requireAllowed(.target)
                let query = try value().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { throw UsageError("Option '\(name)' needs an app name, bundle id, or pid.") }
                guard scanned.target == nil else { throw UsageError("Give the target only once.") }
                scanned.target = query

            case "--dry-run", "--live":
                try requireAllowed(.mode)
                try noValue()
                let mode: ExecutionMode = name == "--live" ? .live : .dryRun
                guard scanned.mode == .environment || scanned.mode == mode else {
                    throw UsageError("--dry-run and --live cannot be combined.")
                }
                scanned.mode = mode

            case "--max-steps":
                try requireAllowed(.maxSteps)
                let raw = try value()
                guard let steps = Int(raw.trimmingCharacters(in: .whitespaces)), steps >= 0 else {
                    throw UsageError("--max-steps needs a whole number >= 0 (0 = unlimited), got '\(raw)'.")
                }
                scanned.maxSteps = steps

            case "--confirm-risky":
                try requireAllowed(.confirmRisky)
                try noValue()
                scanned.confirmRisky = true

            default:
                throw UsageError("Unknown option '\(argument)' for '\(command)'.")
            }
        }
        return scanned
    }
}
