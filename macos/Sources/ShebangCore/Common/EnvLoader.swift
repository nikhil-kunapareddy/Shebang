import Foundation

/// Loads KEY=VALUE pairs from a local `.env` file into the process environment.
/// Variables that already have a non-empty value are never overwritten.
public enum EnvLoader {
    /// `$PWD/.env`, `~/Library/Application Support/Shebang/.env`, then `.env` in the directory containing
    /// the running `.app` bundle (or the executable's directory when not bundled, e.g. the CLI).
    public static var defaultSearchPaths: [URL] {
        let fileManager = FileManager.default
        var paths = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true).appendingPathComponent(".env"),
        ]
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(support.appendingPathComponent("Shebang", isDirectory: true).appendingPathComponent(".env"))
        }
        let bundleURL = Bundle.main.bundleURL
        let hostDirectory = bundleURL.pathExtension == "app" ? bundleURL.deletingLastPathComponent() : bundleURL
        paths.append(hostDirectory.appendingPathComponent(".env"))

        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Applies the first readable file in `searchPaths` (default: `defaultSearchPaths`). Entries may be `.env`
    /// files or directories containing one. Returns the file that was applied, if any.
    @discardableResult
    public static func load(searchPaths: [URL]? = nil) -> URL? {
        for candidate in (searchPaths ?? defaultSearchPaths).map(resolveFile) {
            guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else { continue }

            var applied = 0
            for (key, value) in parse(contents) where isUnset(key) {
                if setenv(key, value, 1) == 0 { applied += 1 }
            }
            Log.app.info("Applied \(applied) variable(s) from \(candidate.path, privacy: .public)")
            return candidate
        }
        return nil
    }

    /// Parses `.env` contents: skips blank lines, `#` comments, and lines without a key; trims keys and values
    /// and strips one pair of matching surrounding quotes.
    static func parse(_ contents: String) -> [(key: String, value: String)] {
        var text = contents
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        var pairs: [(key: String, value: String)] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "="), separator != trimmed.startIndex
            else { continue }

            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            pairs.append((key, value))
        }
        return pairs
    }

    private static func resolveFile(_ url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url.appendingPathComponent(".env")
        }
        return url
    }

    private static func isUnset(_ key: String) -> Bool {
        guard let existing = getenv(key) else { return true }
        return existing.pointee == 0
    }
}
