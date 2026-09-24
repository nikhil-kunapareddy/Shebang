import AppKit
import ApplicationServices
import Foundation
import GhostHandCore

public enum AppLauncherError: Error, LocalizedError, Equatable {
    case blockedBySafetyPolicy(String)
    case applicationNotFound(String)
    case invalidURL(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .blockedBySafetyPolicy(let command):
            return "Launch of '\(command)' was blocked by safety policy."
        case .applicationNotFound(let name):
            return "Could not find an application named '\(name)'."
        case .invalidURL(let url):
            return "Invalid or non-http/https URL '\(url)'."
        case .launchFailed(let detail):
            return "Launch failed: \(detail)"
        }
    }
}

/// Parses "open X" / URL intents from goals, resolves app names through LaunchServices and the standard
/// application folders, launches or re-activates the app, and waits for its window.
public final class WorkspaceAppLauncher: AppLauncher {
    /// How long to wait for a launched app to finish launching and show a window (5 s in the Windows build).
    public var launchTimeout: TimeInterval = 5

    private let directory: ApplicationDirectory
    private let lock = NSLock()
    private var _preferredBrowserName: String?

    public convenience init() {
        self.init(directory: WorkspaceApplicationDirectory())
    }

    init(directory: ApplicationDirectory) {
        self.directory = directory
    }

    /// Browser to use for `launchURL` (e.g. from `browserName(in: goal)`), when it resolves to a web browser.
    /// Otherwise URLs open in the frontmost app if it is a browser, else the default browser.
    public var preferredBrowserName: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _preferredBrowserName
        }
        set {
            lock.lock()
            _preferredBrowserName = newValue
            lock.unlock()
        }
    }

    // MARK: - Goal parsing

    private static let trailingAppRegex = launcherRegex(
        #"\b(?:in|using|with|on)\s+([a-zA-Z0-9\-_ ]+?)(?:\s+browser)?\s*[.!]?\s*$"#)

    /// "open notepad", "switch to discord", ... — shares the decision model's parser so both agree.
    public static func extractAppLaunchCandidates(_ goal: String) -> [String] {
        JevDecisionModel.extractAppLaunchCandidates(goal)
    }

    public func extractAppLaunch(from goal: String) -> (appName: String, launchCommand: String)? {
        let candidates = Self.extractAppLaunchCandidates(goal)
        guard let first = candidates.first else { return nil }

        for candidate in candidates {
            if let url = resolveApplication(named: candidate) {
                return (candidate, url.path)
            }
        }
        // Not installed (or not indexed yet): keep the name and resolve again at launch time.
        return Self.isSafeLaunchCommand(first) ? (first, first) : nil
    }

    public func extractURLLaunch(from goal: String) -> URL? {
        UrlLauncherValidator.extractWebURLs(goal).first
    }

    /// The browser named in a goal ("open brave and search lion", "search lion in firefox"), if installed.
    public func browserName(in goal: String) -> String? {
        var candidates = Self.extractAppLaunchCandidates(goal)
        if let trailing = Self.firstCapture(Self.trailingAppRegex, in: goal)?.trimmingCharacters(in: .whitespaces),
           !trailing.isEmpty {
            candidates.append(trailing)
        }
        return candidates.first { candidate in
            resolveApplication(named: candidate).map(directory.isWebBrowser) ?? false
        }
    }

    // MARK: - Launching

    public func launchApp(named appName: String, launchCommand: String? = nil) async throws -> AppTarget? {
        try Task.checkCancellation()
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = launchCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let explicitCommand = trimmedCommand.isEmpty ? nil : trimmedCommand

        let resolvedFromName = explicitCommand == nil ? resolveApplication(named: name) : nil
        let command = explicitCommand ?? resolvedFromName?.path ?? name
        guard Self.isSafeLaunchCommand(command) else {
            Log.app.warning("Refusing to launch '\(command, privacy: .public)': safety violation")
            throw AppLauncherError.blockedBySafetyPolicy(command)
        }

        var appURL = resolvedFromName ?? resolveApplication(named: command)
        if appURL == nil && command != name { appURL = resolveApplication(named: name) }
        if appURL == nil { appURL = await spotlightMatch(for: name) }
        guard let appURL else {
            Log.app.warning("No application found for '\(name, privacy: .public)'")
            throw AppLauncherError.applicationNotFound(name)
        }

        Log.app.info("Launching '\(name, privacy: .public)' from \(appURL.path, privacy: .public)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app: NSRunningApplication
        do {
            // Also activates (and re-opens a window for) an app that is already running.
            app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw AppLauncherError.launchFailed("\(name): \(error.localizedDescription)")
        }
        return try await waitForTarget(app, fallbackName: name)
    }

    public func launchURL(_ url: URL) async throws -> AppTarget? {
        try Task.checkCancellation()
        guard let validated = UrlLauncherValidator.validatedWebURL(url.absoluteString) else {
            throw AppLauncherError.invalidURL(url.absoluteString)
        }

        guard let browser = selectBrowser(for: validated) else {
            Log.app.warning("No browser registered for http(s); asking the system to open the URL")
            guard NSWorkspace.shared.open(validated) else {
                throw AppLauncherError.launchFailed("could not open \(validated.host ?? "URL")")
            }
            return nil
        }

        Log.app.info("Opening URL on \(validated.host ?? "", privacy: .public) with \(browser.lastPathComponent, privacy: .public)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.open([validated], withApplicationAt: browser, configuration: configuration)
        } catch {
            throw AppLauncherError.launchFailed("\(browser.lastPathComponent): \(error.localizedDescription)")
        }
        return try await waitForTarget(app, fallbackName: browser.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Resolution

    /// Generic and Windows-habit names mapped to macOS apps (bundle ids), consulted after exact name matches.
    static let aliases: [String: String] = [
        "fileexplorer": "com.apple.finder",
        "explorer": "com.apple.finder",
        "finder": "com.apple.finder",
        "taskmanager": "com.apple.ActivityMonitor",
        "notepad": "com.apple.TextEdit",
        "settings": "com.apple.systempreferences",
        "controlpanel": "com.apple.systempreferences",
        "systempreferences": "com.apple.systempreferences",
        "calc": "com.apple.calculator",
        "vscode": "com.microsoft.VSCode",
        "chrome": "com.google.Chrome",
        "edge": "com.microsoft.edgemac",
        "word": "com.microsoft.Word",
        "excel": "com.microsoft.Excel",
        "powerpoint": "com.microsoft.Powerpoint",
        "outlook": "com.microsoft.Outlook",
        "teams": "com.microsoft.teams2",
        "microsoftstore": "com.apple.AppStore",
        "snippingtool": "com.apple.screenshot.launcher",
    ]

    /// Resolves an app name, bundle identifier, or `.app` path to an application bundle URL.
    func resolveApplication(named rawName: String) -> URL? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        if name.contains("/") {
            var path = (name as NSString).expandingTildeInPath
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            guard path.lowercased().hasSuffix(".app"), directory.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }

        if Self.looksLikeBundleIdentifier(name), let url = directory.applicationURL(forBundleIdentifier: name) {
            return url
        }

        if name.lowercased().hasSuffix(".app") { name.removeLast(4) }
        let apps = directory.installedApplications()
        let best = Self.bestMatch(for: name, in: apps)
        if let best, best.score >= Self.exactMatchScore { return best.url }

        if let alias = Self.aliases[Self.alphanumericKey(name)],
           let url = directory.applicationURL(forBundleIdentifier: alias) {
            return url
        }
        return best?.url
    }

    func selectBrowser(for url: URL) -> URL? {
        if let name = preferredBrowserName, let app = resolveApplication(named: name), directory.isWebBrowser(app) {
            return app
        }
        if let front = directory.frontmostApplicationURL(), directory.isWebBrowser(front) {
            return front
        }
        return directory.defaultBrowserURL(for: url)
    }

    private func spotlightMatch(for name: String) async -> URL? {
        let found = await directory.spotlightApplications(named: name)
        let apps = found.map { InstalledApplication(url: $0) }
        return Self.bestMatch(for: name, in: apps)?.url
    }

    static let exactMatchScore = 90

    /// Case-insensitive fuzzy name score: 100 exact, 90 ignoring punctuation, 80 leading words,
    /// 70 all words present (both minus 5 per extra word in the name, at most 20), 50 substring,
    /// 40 name is a prefix of the query; 0 = no match. The penalty keeps "chrome" on Google Chrome
    /// rather than "Chrome Remote Desktop Host Uninstaller".
    static func matchScore(query: String, name: String) -> Int {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let n = name.lowercased()
        if n == q { return 100 }

        let qKey = alphanumericKey(q)
        let nKey = alphanumericKey(n)
        guard !qKey.isEmpty, !nKey.isEmpty else { return 0 }
        if nKey == qKey { return 90 }

        let queryWords = words(q)
        let nameWords = words(n)
        let extraWordPenalty = min(max(nameWords.count - queryWords.count, 0) * 5, 20)
        if nameWords.starts(with: queryWords) { return 80 - extraWordPenalty }
        if Set(queryWords).isSubset(of: Set(nameWords)) { return 70 - extraWordPenalty }

        guard qKey.count >= 3 else { return 0 }
        if nKey.contains(qKey) { return 50 }
        if nKey.count >= 4 && qKey.hasPrefix(nKey) { return 40 }
        return 0
    }

    static func bestMatch(for query: String, in apps: [InstalledApplication]) -> (url: URL, score: Int)? {
        var best: (url: URL, score: Int, length: Int)?
        for app in apps {
            for name in app.names {
                let score = matchScore(query: query, name: name)
                guard score > 0 else { continue }
                if best == nil || score > best!.score || (score == best!.score && name.count < best!.length) {
                    best = (app.url, score, name.count)
                }
            }
        }
        return best.map { ($0.url, $0.score) }
    }

    // MARK: - Safety

    private static let blockedExecutables: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "tcsh", "ksh", "dash", "osascript", "osacompile",
        "python", "python3", "perl", "ruby", "node", "php", "sudo", "su", "launchctl", "diskutil", "rm", "dd",
        "powershell", "pwsh", "mshta", "wscript", "cscript", "rundll32", "regedit", "diskpart",
    ]

    private static let blockedExtensions: Set<String> = [
        "sh", "bash", "zsh", "csh", "command", "tool", "py", "rb", "pl", "js", "php", "scpt", "scptd",
        "applescript", "workflow", "terminal", "jar", "pkg", "mpkg", "bat", "cmd", "ps1", "vbs", "exe", "com", "msi",
    ]

    /// Command-line switches (`-c`, `--eval`, `/c`) and shell metacharacters mean someone is trying to run a command.
    private static let argumentRegex = launcherRegex(#"\s-{1,2}[A-Za-z]|\s/[A-Za-z]\b|[;|&$`<>\r\n]"#)

    /// Only application bundles, bundle identifiers, and plain app names may be launched.
    static func isSafeLaunchCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, firstMatch(argumentRegex, in: trimmed) == nil else { return false }

        var path = trimmed
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let lastComponent = (path as NSString).lastPathComponent.lowercased()
        let pathExtension = (lastComponent as NSString).pathExtension
        if blockedExtensions.contains(pathExtension) { return false }
        if trimmed.contains("/") { return pathExtension == "app" }

        let baseName = (lastComponent as NSString).deletingPathExtension
        return !blockedExecutables.contains(lastComponent) && !blockedExecutables.contains(baseName)
    }

    // MARK: - Waiting for the launched window

    private func waitForTarget(_ app: NSRunningApplication, fallbackName: String) async throws -> AppTarget? {
        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if app.isTerminated { return nil }
            if app.isFinishedLaunching, let window = LaunchedWindow.front(of: app.processIdentifier) {
                return makeTarget(app, window: window, fallbackName: fallbackName)
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        guard !app.isTerminated else { return nil }
        Log.app.notice("'\(fallbackName, privacy: .public)' showed no window within \(self.launchTimeout, privacy: .public)s")
        return makeTarget(app, window: LaunchedWindow.front(of: app.processIdentifier), fallbackName: fallbackName)
    }

    private func makeTarget(_ app: NSRunningApplication, window: LaunchedWindow?, fallbackName: String) -> AppTarget {
        let pid = app.processIdentifier
        return AppTarget(
            processId: pid,
            processName: app.localizedName ?? fallbackName,
            bundleIdentifier: app.bundleIdentifier ?? "",
            executablePath: app.executableURL?.path ?? "",
            windowTitle: LaunchedWindow.focusedTitle(of: pid) ?? window?.title ?? "",
            windowNumber: window?.number ?? 0,
            windowBounds: window?.bounds ?? .zero
        )
    }

    // MARK: - Helpers

    private static func looksLikeBundleIdentifier(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+){2,}$"#, options: .regularExpression) != nil
    }

    static func alphanumericKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    private static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func launcherRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            preconditionFailure("Invalid regex \(pattern): \(error)")
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = firstMatch(regex, in: text), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// An installed application bundle and the names it can be referred to by.
struct InstalledApplication: Equatable {
    var url: URL
    var names: [String]

    init(url: URL, names: [String]? = nil) {
        self.url = url
        self.names = names ?? [url.deletingPathExtension().lastPathComponent]
    }
}

/// Seam over LaunchServices and the file system so resolution is testable without real apps.
protocol ApplicationDirectory: AnyObject {
    func installedApplications() -> [InstalledApplication]
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
    func fileExists(atPath path: String) -> Bool
    func isWebBrowser(_ appURL: URL) -> Bool
    func defaultBrowserURL(for url: URL) -> URL?
    func frontmostApplicationURL() -> URL?
    func spotlightApplications(named name: String) async -> [URL]
}

final class WorkspaceApplicationDirectory: ApplicationDirectory {
    private static let cacheLifetime: TimeInterval = 30
    private static let spotlightTimeout: TimeInterval = 2

    private let lock = NSLock()
    private var appCache: (date: Date, apps: [InstalledApplication])?
    private var browserCache: (date: Date, paths: Set<String>)?

    static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        ]
    }

    func installedApplications() -> [InstalledApplication] {
        lock.lock()
        if let cache = appCache, Date().timeIntervalSince(cache.date) < Self.cacheLifetime {
            lock.unlock()
            return cache.apps
        }
        lock.unlock()

        let apps = Self.scan()
        lock.lock()
        appCache = (Date(), apps)
        lock.unlock()
        return apps
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func isWebBrowser(_ appURL: URL) -> Bool {
        lock.lock()
        var paths = browserCache.flatMap { Date().timeIntervalSince($0.date) < Self.cacheLifetime ? $0.paths : nil }
        lock.unlock()

        if paths == nil {
            let probe = URL(string: "https://example.com")!
            let fresh = Set(NSWorkspace.shared.urlsForApplications(toOpen: probe).map(Self.canonicalPath))
            lock.lock()
            browserCache = (Date(), fresh)
            lock.unlock()
            paths = fresh
        }
        return paths?.contains(Self.canonicalPath(appURL)) ?? false
    }

    /// Safari and other cryptex apps are reachable through both /Applications and their real location.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func defaultBrowserURL(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    func frontmostApplicationURL() -> URL? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        return app.bundleURL
    }

    func spotlightApplications(named name: String) async -> [URL] {
        await SpotlightApplicationQuery.run(name: name, timeout: Self.spotlightTimeout)
    }

    private static func scan() -> [InstalledApplication] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var bundles: [URL] = []

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted { bundles.append(url) }
        }

        for directory in searchDirectories {
            guard let items = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])
            else { continue }
            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let nested = try? fileManager.contentsOfDirectory(
                            at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    // Vendor folders such as "/Applications/Microsoft Office/…".
                    nested.filter { $0.pathExtension.lowercased() == "app" }.forEach(add)
                }
            }
        }

        // Apps running from elsewhere (disk images, Downloads, developer builds).
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL { add(url) }
        }

        return bundles.map { url in
            let fileName = url.deletingPathExtension().lastPathComponent
            var names = [fileName]
            var display = fileManager.displayName(atPath: url.path)
            if display.lowercased().hasSuffix(".app") { display.removeLast(4) }
            if !display.isEmpty && display != fileName { names.append(display) }
            return InstalledApplication(url: url, names: names)
        }
    }
}

/// Spotlight lookup for application bundles by file name, bounded by a timeout.
@MainActor
private final class SpotlightApplicationQuery {
    private let query = NSMetadataQuery()
    private var continuation: CheckedContinuation<[URL], Never>?
    private var observer: NSObjectProtocol?

    static func run(name: String, timeout: TimeInterval) async -> [URL] {
        let search = SpotlightApplicationQuery()
        search.query.searchScopes = [NSMetadataQueryLocalComputerScope]
        search.query.predicate = NSPredicate(
            format: "kMDItemContentType == 'com.apple.application-bundle' AND kMDItemFSName CONTAINS[cd] %@", name)
        return await withCheckedContinuation { continuation in
            search.begin(continuation: continuation, timeout: timeout)
        }
    }

    private func begin(continuation: CheckedContinuation<[URL], Never>, timeout: TimeInterval) {
        self.continuation = continuation
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.finish() }
        }
        guard query.start() else {
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { self.finish() }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil

        let urls = (0..<query.resultCount).compactMap { index -> URL? in
            let item = query.result(at: index) as? NSMetadataItem
            return (item?.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) }
        }
        continuation.resume(returning: urls)
    }
}

/// Front-most normal window of a process, from the window server (and AX for the title when trusted).
private struct LaunchedWindow {
    var number: Int
    var bounds: CGRect
    var title: String

    static func front(of pid: pid_t) -> LaunchedWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }

        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 50, bounds.height >= 50
            else { continue }
            return LaunchedWindow(
                number: info[kCGWindowNumber as String] as? Int ?? 0,
                bounds: bounds,
                title: info[kCGWindowName as String] as? String ?? ""
            )
        }
        return nil
    }

    static func focusedTitle(of pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}
