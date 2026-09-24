import AppKit
import Darwin
import ShebangCore
import ShebangPlatform

/// A running app as far as `--target` matching is concerned.
struct RunningAppRecord: Equatable {
    var pid: Int32
    var name: String
    var bundleIdentifier: String
    var executableName: String
    /// Regular (Dock) apps win over agents and background helpers with the same name.
    var isRegular: Bool

    var summary: String {
        bundleIdentifier.isEmpty ? "\(name) (PID \(pid))" : "\(name) (\(bundleIdentifier), PID \(pid))"
    }
}

enum TargetLookupResult: Equatable {
    case found(RunningAppRecord)
    case ambiguous([RunningAppRecord])
    case notFound
}

enum TargetSelection {
    static let countdownSeconds = 3

    /// Terminal emulators; capturing one of these almost always means the user did not switch apps in time.
    static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]

    /// Resolves the target, printing progress and failures. Returns nil when there is nothing to work on.
    static func resolve(_ selector: TargetSelector, tracker: FrontmostWindowTracker) async -> AppTarget? {
        switch selector {
        case .query(let query):
            switch lookup(query, in: runningApps()) {
            case .found(let app):
                guard let target = tracker.target(forProcessID: app.pid) else {
                    Console.line("'\(app.name)' (PID \(app.pid)) is no longer running.", .red)
                    return nil
                }
                return target
            case .ambiguous(let apps):
                Console.line("'\(query)' matches several apps:", .red)
                for app in apps { Console.line("  \(app.summary)") }
                Console.line("Use the full app name, the bundle identifier, or the pid.")
                return nil
            case .notFound:
                Console.line("No running app matches '\(query)'.", .red)
                Console.line("Pass the name (Safari), bundle identifier (com.apple.Safari), or pid of a running app.")
                return nil
            }

        case .frontmost:
            Console.line("Switch to the target app now: capturing the frontmost app in \(countdownSeconds) seconds.")
            Console.line("(shebang cannot skip the terminal it runs in, so bring the target app to the front.)", .dim)
            for remaining in stride(from: countdownSeconds, to: 0, by: -1) {
                Console.write("\(remaining)... ")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            Console.line("Capturing!\n")
            guard let target = tracker.captureFrontmost() else {
                Console.line("Failed to capture the frontmost app. Use --target <app> instead.", .red)
                return nil
            }
            return target
        }
    }

    static func printTarget(_ target: AppTarget) {
        let title = target.windowTitle.isEmpty ? "(no window title)" : "\"\(target.windowTitle)\""
        let bundle = target.bundleIdentifier.isEmpty ? "" : "\(target.bundleIdentifier), "
        let bounds = target.windowBounds
        Console.line("Target window: \(title)", .cyan)
        Console.line("App: \(target.processName) (\(bundle)PID \(target.processId))", .cyan)
        if bounds.isEmpty {
            Console.line("Bounds: unknown (no window found)", .cyan)
        } else {
            Console.line("Bounds: \(Int(bounds.width))x\(Int(bounds.height)) at (\(Int(bounds.minX)), \(Int(bounds.minY)))",
                         .cyan)
        }
    }

    // MARK: - Matching

    static func runningApps() -> [RunningAppRecord] {
        let ownPID = getpid()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, app.processIdentifier != ownPID else { return nil }
            return RunningAppRecord(
                pid: app.processIdentifier,
                name: app.localizedName ?? "",
                bundleIdentifier: app.bundleIdentifier ?? "",
                executableName: app.executableURL?.lastPathComponent ?? "",
                isRegular: app.activationPolicy == .regular)
        }
    }

    /// pid, then exact bundle identifier, then exact app or executable name (a trailing `.app` is ignored),
    /// then a unique name prefix among regular apps. All comparisons are case-insensitive.
    static func lookup(_ query: String, in apps: [RunningAppRecord]) -> TargetLookupResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = Int32(trimmed) {
            return apps.first { $0.pid == pid }.map(TargetLookupResult.found) ?? .notFound
        }

        let lower = trimmed.lowercased()
        let name = lower.hasSuffix(".app") ? String(lower.dropLast(4)) : lower
        guard !name.isEmpty else { return .notFound }
        let ordered = apps.filter(\.isRegular) + apps.filter { !$0.isRegular }

        if let app = ordered.first(where: { $0.bundleIdentifier.lowercased() == lower }) {
            return .found(app)
        }
        if let app = ordered.first(where: { $0.name.lowercased() == name || $0.executableName.lowercased() == name }) {
            return .found(app)
        }
        let prefixed = ordered.filter { $0.isRegular && $0.name.lowercased().hasPrefix(name) }
        switch prefixed.count {
        case 0: return .notFound
        case 1: return .found(prefixed[0])
        default: return .ambiguous(prefixed)
        }
    }

    // MARK: - Terminal detection

    /// True when `target` is an ancestor process of this CLI, i.e. the terminal (or IDE) running it.
    static func isHostTerminal(_ target: AppTarget) -> Bool {
        ancestorPIDs().contains(target.processId)
    }

    static func looksLikeTerminal(_ target: AppTarget) -> Bool {
        isHostTerminal(target) || terminalBundleIdentifiers.contains(target.bundleIdentifier.lowercased())
    }

    private static func ancestorPIDs() -> Set<Int32> {
        var ancestors = Set<Int32>()
        var pid = getppid()
        while pid > 1, ancestors.count < 64, ancestors.insert(pid).inserted {
            guard let parent = parentPID(of: pid) else { break }
            pid = parent
        }
        return ancestors
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
