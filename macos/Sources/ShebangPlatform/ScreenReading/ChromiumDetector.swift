import AppKit
import Foundation
import ShebangCore

/// Chromium, Electron, and CEF apps only build their web accessibility tree once an assistive client
/// asks for it via `AXManualAccessibility` (Electron) / `AXEnhancedUserInterface` (Chrome).
enum ChromiumDetector {
    static let knownBundleIdentifiers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser",
        "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.hnc.Discord", "com.spotify.client", "notion.id",
        "com.microsoft.teams2",
    ]

    static let embeddedFrameworks = [
        "Contents/Frameworks/Electron Framework.framework",
        "Contents/Frameworks/Chromium Embedded Framework.framework",
    ]

    static func isChromiumBased(
        bundleIdentifier: String,
        bundleURL: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        if knownBundleIdentifiers.contains(bundleIdentifier) { return true }
        guard let bundleURL else { return false }
        return embeddedFrameworks.contains { fileExists(bundleURL.appendingPathComponent($0).path) }
    }

    static func isChromiumBased(_ target: AppTarget) -> Bool {
        let bundleURL = NSRunningApplication(processIdentifier: target.processId)?.bundleURL
            ?? appBundleURL(fromExecutable: target.executablePath)
        return isChromiumBased(bundleIdentifier: target.bundleIdentifier, bundleURL: bundleURL)
    }

    /// `/Applications/Foo.app/Contents/MacOS/Foo` → `/Applications/Foo.app`.
    static func appBundleURL(fromExecutable path: String) -> URL? {
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
    }
}
