import Foundation
import Testing
@testable import ShebangPlatform

/// In-memory stand-in for LaunchServices and the application folders. Nothing is ever launched.
private final class FakeApplicationDirectory: ApplicationDirectory {
    static func app(_ path: String, names: [String]? = nil) -> InstalledApplication {
        InstalledApplication(url: URL(fileURLWithPath: path), names: names)
    }

    var apps: [InstalledApplication] = [
        app("/Applications/Safari.app"),
        app("/Applications/Google Chrome.app"),
        app("/Applications/Brave Browser.app"),
        app("/Applications/Visual Studio Code.app"),
        app("/Applications/Spotify.app"),
        app("/Applications/Discord.app"),
        app("/Applications/VLC.app"),
        app("/Applications/Microsoft Word.app"),
        app("/Applications/Microsoft Word Viewer Helper.app"),
        app("/System/Applications/Calculator.app", names: ["Calculator", "Rechner"]),
        app("/System/Applications/System Settings.app"),
        app("/System/Applications/TextEdit.app"),
        app("/System/Applications/Utilities/Activity Monitor.app"),
    ]

    var bundleIdentifiers: [String: URL] = [
        "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app"),
        "com.apple.finder": URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        "com.apple.ActivityMonitor": URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        "com.apple.TextEdit": URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
        "com.apple.systempreferences": URL(fileURLWithPath: "/System/Applications/System Settings.app"),
        "com.apple.calculator": URL(fileURLWithPath: "/System/Applications/Calculator.app"),
        "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
    ]

    var existingPaths: Set<String> = ["/Applications/Safari.app"]
    var browsers: Set<String> = [
        "/Applications/Safari.app", "/Applications/Google Chrome.app", "/Applications/Brave Browser.app",
    ]
    var defaultBrowser: URL? = URL(fileURLWithPath: "/Applications/Safari.app")
    var frontmost: URL?
    private(set) var spotlightQueries: [String] = []

    func installedApplications() -> [InstalledApplication] { apps }
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? { bundleIdentifiers[bundleIdentifier] }
    func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
    func isWebBrowser(_ appURL: URL) -> Bool { browsers.contains(appURL.path) }
    func defaultBrowserURL(for url: URL) -> URL? { defaultBrowser }
    func frontmostApplicationURL() -> URL? { frontmost }

    func spotlightApplications(named name: String) async -> [URL] {
        spotlightQueries.append(name)
        return []
    }
}

@Suite struct WorkspaceAppLauncherTests {
    private let directory = FakeApplicationDirectory()
    private var launcher: WorkspaceAppLauncher { WorkspaceAppLauncher(directory: directory) }

    // MARK: Resolution

    @Test(arguments: [
        ("chrome", "Google Chrome"),
        ("Google Chrome", "Google Chrome"),
        ("brave", "Brave Browser"),
        ("CALCULATOR", "Calculator"),
        ("rechner", "Calculator"),
        ("calc", "Calculator"),
        ("finder", "Finder"),
        ("settings", "System Settings"),
        ("system preferences", "System Settings"),
        ("code", "Visual Studio Code"),
        ("vs code", "Visual Studio Code"),
        ("word", "Microsoft Word"),
        ("spotify music", "Spotify"),
        ("com.apple.Safari", "Safari"),
        ("Safari.app", "Safari"),
        ("/Applications/Safari.app/", "Safari"),
    ])
    func resolvesAppNamesFuzzily(query: String, expected: String) throws {
        let url = try #require(launcher.resolveApplication(named: query))
        #expect(url.deletingPathExtension().lastPathComponent == expected)
    }

    @Test(arguments: ["nonexistentapp", "zz", "/tmp/evil.app", "/Applications/Safari.app/Contents/MacOS/Safari", ""])
    func unknownAppsDoNotResolve(query: String) {
        #expect(launcher.resolveApplication(named: query) == nil)
    }

    @Test func installedAppNamedLikeAnAliasWinsOverTheAlias() throws {
        directory.apps.append(FakeApplicationDirectory.app("/Applications/Settings.app"))
        let url = try #require(launcher.resolveApplication(named: "settings"))
        #expect(url.lastPathComponent == "Settings.app")
    }

    @Test func matchScoreOrdering() {
        #expect(WorkspaceAppLauncher.matchScore(query: "safari", name: "Safari") == 100)
        #expect(WorkspaceAppLauncher.matchScore(query: "facetime", name: "Face Time") == 90)
        #expect(WorkspaceAppLauncher.matchScore(query: "brave", name: "Brave Browser") == 75)
        #expect(WorkspaceAppLauncher.matchScore(query: "chrome", name: "Google Chrome") == 65)
        #expect(WorkspaceAppLauncher.matchScore(query: "chrome", name: "Chrome Remote Desktop Host Uninstaller") == 60)
        #expect(WorkspaceAppLauncher.matchScore(query: "calc", name: "Calculator") == 50)
        #expect(WorkspaceAppLauncher.matchScore(query: "ca", name: "Calculator") == 0)
        #expect(WorkspaceAppLauncher.matchScore(query: "photoshop", name: "Safari") == 0)
    }

    // MARK: Safety

    @Test(arguments: [
        "powershell.exe -enc dGVzdA==",
        "cmd.exe /c del *.*",
        "rundll32.exe",
        "format.com",
        "/bin/zsh",
        "bash",
        "osascript -e 'tell application \"Finder\" to delete'",
        "/usr/bin/python3",
        "~/Desktop/run.command",
        "install.sh",
        "Safari; rm -rf ~",
        "$(reboot)",
        "/Volumes/Setup/Installer.pkg",
        "/Applications/Safari.app/Contents/MacOS/Safari",
    ])
    func maliciousCommands_areBlockedBySafetyPolicy(command: String) async {
        do {
            _ = try await launcher.launchApp(named: command)
            Issue.record("Expected '\(command)' to be blocked")
        } catch {
            #expect(error as? AppLauncherError == .blockedBySafetyPolicy(command))
            #expect(error.localizedDescription.contains("safety policy"))
        }
        #expect(directory.spotlightQueries.isEmpty)
    }

    @Test(arguments: [
        "Safari", "Visual Studio Code", "com.apple.Safari", "/Applications/Safari.app",
        "/System/Applications/Calculator.app/", "Microsoft Word - Document", "iTerm",
    ])
    func safeCommandsAreAllowed(command: String) {
        #expect(WorkspaceAppLauncher.isSafeLaunchCommand(command))
    }

    @Test func unresolvableApp_throwsNotFoundAfterSpotlight() async {
        await #expect(throws: AppLauncherError.applicationNotFound("definitely not installed")) {
            _ = try await launcher.launchApp(named: "definitely not installed")
        }
        #expect(directory.spotlightQueries == ["definitely not installed"])
    }

    @Test func cancelledLaunch_throwsCancellationError() async {
        let launcher = self.launcher
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await launcher.launchApp(named: "Safari")
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: URLs and browsers

    @Test(arguments: ["ftp://example.com/file", "javascript:alert(1)", "file:///etc/passwd", "https://user:pw@example.com"])
    func launchURL_rejectsNonWebURLs(raw: String) async throws {
        let url = try #require(URL(string: raw))
        await #expect(throws: AppLauncherError.invalidURL(raw)) {
            _ = try await launcher.launchURL(url)
        }
    }

    @Test func browserSelection_prefersNamedBrowserThenFrontmostBrowserThenDefault() {
        let launcher = self.launcher
        let url = URL(string: "https://www.google.com/search?q=lion")!

        launcher.preferredBrowserName = "brave"
        #expect(launcher.selectBrowser(for: url)?.lastPathComponent == "Brave Browser.app")

        launcher.preferredBrowserName = "spotify" // not a browser
        directory.frontmost = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        #expect(launcher.selectBrowser(for: url)?.lastPathComponent == "Google Chrome.app")

        launcher.preferredBrowserName = nil
        directory.frontmost = URL(fileURLWithPath: "/Applications/Spotify.app")
        #expect(launcher.selectBrowser(for: url)?.lastPathComponent == "Safari.app")
    }

    @Test(arguments: [
        ("open brave and search lion", "brave"),
        ("search lion in brave", "brave"),
        ("search python in chrome", "chrome"),
        ("open safari and go to github.com", "safari"),
    ])
    func browserName_findsInstalledBrowserInGoal(goal: String, expected: String) {
        #expect(launcher.browserName(in: goal) == expected)
    }

    @Test(arguments: ["open spotify and play any song of aditya rikhari", "search about lion", "open firefox and search lion"])
    func browserName_isNilWithoutAnInstalledBrowser(goal: String) {
        #expect(launcher.browserName(in: goal) == nil)
    }
}

/// Resolves against the real LaunchServices database and application folders without launching
/// anything; run with `SHEBANG_LIVE_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SHEBANG_LIVE_TESTS"] == "1"))
struct WorkspaceAppLauncherLiveTests {
    private let launcher = WorkspaceAppLauncher()

    @Test(arguments: [
        ("Calculator", "Calculator"),
        ("finder", "Finder"),
        ("activity monitor", "Activity Monitor"),
        ("settings", "System Settings"),
        ("com.apple.Safari", "Safari"),
    ])
    func resolvesSystemApps(query: String, expected: String) throws {
        let url = try #require(launcher.resolveApplication(named: query))
        #expect(url.deletingPathExtension().lastPathComponent == expected)
    }

    @Test func safariIsAWebBrowserAndSomeBrowserHandlesHTTPS() throws {
        let directory = WorkspaceApplicationDirectory()
        let safari = try #require(directory.applicationURL(forBundleIdentifier: "com.apple.Safari"))
        #expect(directory.isWebBrowser(safari))
        #expect(directory.defaultBrowserURL(for: URL(string: "https://example.com")!) != nil)
        #expect(!directory.installedApplications().isEmpty)
    }
}
