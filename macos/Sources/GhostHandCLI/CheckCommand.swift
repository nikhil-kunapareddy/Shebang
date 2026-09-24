import Foundation
import GhostHandCore
import GhostHandPlatform

/// `ghosthand check`: configuration, API key presence, permissions, then a live Jev call.
/// Exits 0 only when the Jev connection is verified.
enum CheckCommand {
    static func execute(envFile: URL?) async -> Int32 {
        Console.line("Running environment checks...")
        Console.line("  System: \(GhostHandCLI.platformDescription)")
        if let envFile {
            Console.line("  .env: \(envFile.path)")
        } else {
            Console.line("  .env: none found (searched: \(EnvLoader.defaultSearchPaths.map(\.path).joined(separator: ", ")))")
        }

        let apiKey = ResolvedAPIKey.resolve()
        if let apiKey {
            Console.line("  AI_GATEWAY_API_KEY: \(apiKey.masked) (from \(apiKey.source))", .green)
        } else {
            Console.line("  AI_GATEWAY_API_KEY: [NOT CONFIGURED]", .yellow)
            Console.line("    \(ResolvedAPIKey.missingKeyHelp)")
        }

        let accessibility = Permissions.isAccessibilityTrusted
        Console.line("\nmacOS permissions (granted to the terminal app that runs this CLI):")
        if accessibility {
            Console.line("  Accessibility: granted", .green)
        } else {
            Console.line("  Accessibility: NOT GRANTED (required to read and operate other apps)", .yellow)
            Console.line("    Add your terminal app in System Settings > Privacy & Security > Accessibility,")
            Console.line("    then quit and reopen it. GhostHand.app needs its own grant.")
        }
        if Permissions.hasScreenRecording {
            Console.line("  Screen Recording: granted", .green)
        } else {
            Console.line("  Screen Recording: not granted (optional: OCR fallback for apps without accessible controls)")
            Console.line("    Enable it in System Settings > Privacy & Security > Screen Recording.")
        }

        guard let apiKey else {
            Console.line("\nCannot perform Jev evaluation without an API key.", .yellow)
            return 1
        }

        var options = JevOptions.fromEnvironment()
        options.apiKey = apiKey.value
        Console.line("\nTesting live Jev model via Vercel AI Gateway...")
        Console.line("  Gateway Base URL: \(options.baseURL)")
        Console.line("  Model: \(options.modelId)")
        Console.line("  Zero Data Retention: \(options.zeroDataRetention)")

        do {
            let summary = try await JevClient(options: options).checkConnection()
            Console.line("\n[SUCCESS] \(summary)", .green)
            if accessibility {
                Console.line("\nAll diagnostic checks passed. Your API key and Gateway connection are verified.")
            } else {
                Console.line("\nAPI key and Gateway connection verified. Grant Accessibility to your terminal to use")
                Console.line("'ghosthand read' and 'ghosthand run'.")
            }
            return 0
        } catch let error as JevError {
            switch error {
            case .auth:
                Console.line("\n[AUTH ERROR] \(error.localizedDescription)", .red)
                Console.line("Double-check the API key (AI_GATEWAY_API_KEY in .env, the environment, or the Keychain).")
            case .transient:
                Console.line("\n[GATEWAY ERROR] \(error.localizedDescription)", .red)
            case .protocolError:
                Console.line("\n[ERROR] \(error.localizedDescription)", .red)
            }
            return 1
        } catch {
            Console.line("\n[ERROR] Unexpected error: \(error.localizedDescription)", .red)
            return 1
        }
    }
}
