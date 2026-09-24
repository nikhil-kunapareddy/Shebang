import Foundation
import GhostHandCore
import GhostHandPlatform

/// Entry point: parse, load `.env`, dispatch. Exit codes: 0 success, 1 failure, 2 usage error.
enum GhostHandCLI {
    /// Used when the binary runs outside GhostHand.app (e.g. `swift run ghosthand`).
    static let fallbackVersion = "0.1.0"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallbackVersion
    }

    static var platformDescription: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(arch)"
    }

    static func main(arguments: [String]) async -> Int32 {
        let command: CLICommand
        do {
            command = try CLIParser.parse(arguments)
        } catch {
            let message = (error as? UsageError)?.message ?? error.localizedDescription
            Console.error("ghosthand: \(message)")
            Console.error("Run 'ghosthand help' for usage.")
            return 2
        }

        switch command {
        case .help:
            Console.line(helpText)
            return 0
        case .version:
            Console.line("ghosthand \(version) (\(platformDescription))")
            return 0
        case .check, .read, .run:
            break
        }

        let envFile = EnvLoader.load()
        Console.line("GhostHand CLI v\(version)", .bold)

        switch command {
        case .check:
            return await CheckCommand.execute(envFile: envFile)
        case .read(let target):
            return await ReadCommand.execute(target: target)
        case .run(let arguments):
            return await RunCommand.execute(arguments)
        case .help, .version:
            return 0
        }
    }

    static let helpText = """
        GhostHand CLI v\(version): diagnostics and agent runs for the GhostHand macOS app.

        Usage: ghosthand <command> [options]

        Commands:
          check                 Check the API key, macOS permissions, and Jev connectivity
          read [<app>]          Print the ranked UI elements GhostHand sees in an app's focused
                                window (alias: snapshot)
          run "<goal>"          Run the agent loop on an app (dry-run unless DRY_RUN=false or --live)
          dry-run "<goal>"      Same as run --dry-run
          version               Print the version
          help                  Show this help

        Target (read, run, dry-run):
          -t, --target <app>    App name, bundle identifier, or process id of a running app
                                (alias: --process). Without it, ghosthand counts down 3 seconds and
                                captures the frontmost app: switch to the target app during the
                                countdown.

        Run options:
          --dry-run             Simulate actions; no clicks or keystrokes are sent
          --live                Send real clicks and keystrokes to the target app
          --max-steps <n>       Stop after n steps; 0 = unlimited (default: MAX_STEPS_PER_RUN, else 10)
          --confirm-risky       Have Jev score each click and ask here (y/N) before high-risk ones

        Configuration comes from the environment and the first .env file found in: the current
        directory, ~/Library/Application Support/GhostHand, then next to GhostHand.app (or this
        binary). Existing environment variables win. The API key is AI_GATEWAY_API_KEY, else the
        Keychain entry saved by GhostHand.app. macOS permissions (Accessibility, Screen Recording)
        apply to the terminal app that runs ghosthand. Press Ctrl-C to cancel a run.

        Exit status: 0 success, 1 failure, 2 usage error.
        """
}

/// Where the API key came from; the key itself is never printed.
struct ResolvedAPIKey {
    let value: String
    let source: String

    /// First and last four characters for long keys, e.g. `vck_...a1b2`.
    var masked: String {
        value.count > 16 ? "\(value.prefix(4))...\(value.suffix(4))" : "[CONFIGURED]"
    }

    /// `AI_GATEWAY_API_KEY` (environment or `.env`) wins over the Keychain entry saved by GhostHand.app.
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedAPIKey? {
        let variable = KeychainCredentialStore.environmentVariable
        if let key = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return ResolvedAPIKey(value: key, source: "environment or .env")
        }
        let keychain = KeychainCredentialStore(environment: [:])
        if let key = keychain.apiKey() {
            return ResolvedAPIKey(value: key, source: "Keychain, service \(keychain.service)")
        }
        return nil
    }

    static let missingKeyHelp = """
        Set AI_GATEWAY_API_KEY in the environment or a .env file, or save the key in GhostHand.app \
        (stored in the Keychain).
        """
}
