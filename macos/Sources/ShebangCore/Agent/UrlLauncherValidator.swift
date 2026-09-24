import Foundation

public enum UrlLauncherValidator {
    private static let urlRegex = NSRegularExpression(literal: #"https?://[^\s"'<>]+"#, options: .caseInsensitive)

    private static let domainRegex = NSRegularExpression(
        literal: #"(?:open|go\s+to|visit)\s+([a-zA-Z0-9\-_]+\.[a-zA-Z]{2,}(?:/[^\s]*)?)"#, options: .caseInsensitive)

    private static let searchOnRegex = NSRegularExpression(
        literal: #"(?:search|look)\s+for\s+(.+?)\s+(?:on|in)\s+([a-zA-Z0-9\-_]+)"#, options: .caseInsensitive)

    private static let googleRegex = NSRegularExpression(
        literal: #"^(?:please\s+)?(?:google|search\s+google\s+for)\s+(.+)$"#, options: .caseInsensitive)

    private static let youtubeRegex = NSRegularExpression(
        literal: #"^(?:please\s+)?(?:youtube|search\s+youtube\s+for)\s+(.+)$"#, options: .caseInsensitive)

    private static let chainedRegex = NSRegularExpression(
        literal: #"(?:(?:open|launch|start)\s+[a-zA-Z0-9_\- ]+?\s+(?:and|then)\s+)?(?:search|go\s+to|open)\s+(?:for\s+)?([a-zA-Z0-9_\-]+)\s+(?:and|then)\s+(?:search|play|find|look\s+up)\s+(?:for\s+)?(.+?)(?:\.|$)"#,
        options: .caseInsensitive)

    private static let musicRegex = NSRegularExpression(
        literal: #"(?:(?:open|launch|start)\s+([a-zA-Z0-9_\- ]+?)\s+(?:and|then)\s+)?(?:play|listen\s+to|stream)(?:\s+(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|tracks?\s+(?:of|by)))?\s+(.+?)(?:\s+(?:on|in|using|with)\s+([a-zA-Z0-9_\-]+)|\.|$)"#,
        options: .caseInsensitive)

    private static let musicPrefixRegex = NSRegularExpression(
        literal: #"^(?:any\s+song\s+(?:of|by)|songs?\s+(?:of|by)|music\s+(?:of|by)|track\s+(?:of|by))\s+"#, options: .caseInsensitive)

    private static let generalSearchRegex = NSRegularExpression(
        literal: #"(?:(?:open|launch|start)\s+[a-zA-Z0-9_\- ]+?\s+(?:and|then)\s+)?(?:search|look\s+up|find|query)(?:\s+(?:for|about|on|regarding|the\s+web\s+for))?\s+(.+?)(?:\s+(?:on|in|using|with)\s+([a-zA-Z0-9\-_]+)|\.|$)"#,
        options: .caseInsensitive)

    /// Returns the URL when `rawURL` is an absolute http(s) URL with a real host and no embedded credentials.
    public static func validatedWebURL(_ rawURL: String?) -> URL? {
        guard let rawURL, !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Strip trailing punctuation like period, comma, paren.
        var trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".,)];".contains(last) { trimmed.removeLast() }

        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, host.count >= 3,
              components.user == nil, components.password == nil
        else { return nil }
        return url
    }

    public static func isValidWebURL(_ rawURL: String?) -> Bool {
        validatedWebURL(rawURL) != nil
    }

    public static func extractWebURLs(_ prompt: String) -> [URL] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // 1. Explicit http/https URLs in the text.
        let explicit = urlRegex.matches(in: prompt).compactMap { match in
            match.group(0, in: prompt).flatMap(validatedWebURL)
        }
        if !explicit.isEmpty { return explicit }

        // 2. Bare domain ("open github.com", "go to wikipedia.org", "visit reddit.com").
        if let match = domainRegex.firstMatch(in: prompt), let domain = match.group(1, in: prompt),
           let url = validatedWebURL("https://\(domain.trimmingCharacters(in: .whitespaces))") {
            return [url]
        }

        // 3. Search on a named engine ("search for Adele on youtube").
        if let match = searchOnRegex.firstMatch(in: prompt),
           let query = match.group(1, in: prompt).map(cleanQuery),
           let engine = match.group(2, in: prompt)?.lowercased(),
           let url = validatedWebURL(searchURL(engine: engine, query: query, includeSpotify: false)) {
            return [url]
        }

        // 4. Direct search command ("google <query>", "youtube <query>").
        if let match = googleRegex.firstMatch(in: prompt), let query = match.group(1, in: prompt).map(cleanQuery),
           !query.isEmpty, let url = validatedWebURL("https://www.google.com/search?q=\(query.escapedDataString)") {
            return [url]
        }
        if let match = youtubeRegex.firstMatch(in: prompt), let query = match.group(1, in: prompt).map(cleanQuery),
           !query.isEmpty, let url = validatedWebURL("https://www.youtube.com/results?search_query=\(query.escapedDataString)") {
            return [url]
        }

        // 5. Chained platform and query ("open brave and search for youtube and search honey singh songs").
        if let match = chainedRegex.firstMatch(in: prompt),
           let platform = match.group(1, in: prompt)?.lowercased(),
           let query = match.group(2, in: prompt).map(cleanQuery), query.count > 1,
           let url = validatedWebURL(searchURL(engine: platform, query: query, includeSpotify: true)) {
            return [url]
        }

        // 6. Music streaming ("open spotify and play any song of aditya rikhari", "play X on spotify").
        if let match = musicRegex.firstMatch(in: prompt), var query = match.group(2, in: prompt).map(cleanQuery) {
            query = musicPrefixRegex.replacingMatches(in: query, with: "").trimmingCharacters(in: .whitespaces)
            let platform = (match.group(3, in: prompt) ?? match.group(1, in: prompt) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if query.count > 1 {
                let streamURL = platform.contains("spotify")
                    ? "https://open.spotify.com/search/\(query.escapedDataString)"
                    : "https://www.youtube.com/results?search_query=\(query.escapedDataString)"
                if let url = validatedWebURL(streamURL) { return [url] }
            }
        }

        // 7. General search ("open brave and search lion", "search about lion", "search python in chrome").
        if let match = generalSearchRegex.firstMatch(in: prompt),
           let query = match.group(1, in: prompt).map(cleanQuery),
           query.count > 1, query.lowercased() != "there" {
            let engine = match.group(2, in: prompt)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if let url = validatedWebURL(searchURL(engine: engine, query: query, includeSpotify: true)) {
                return [url]
            }
        }

        return []
    }

    private static func cleanQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func searchURL(engine: String, query: String, includeSpotify: Bool) -> String {
        let q = query.escapedDataString
        switch engine {
        case "youtube": return "https://www.youtube.com/results?search_query=\(q)"
        case "spotify" where includeSpotify: return "https://open.spotify.com/search/\(q)"
        case "bing": return "https://www.bing.com/search?q=\(q)"
        case "reddit": return "https://www.reddit.com/search/?q=\(q)"
        case "wikipedia": return "https://en.wikipedia.org/wiki/Special:Search?search=\(q)"
        default: return "https://www.google.com/search?q=\(q)"
        }
    }
}
