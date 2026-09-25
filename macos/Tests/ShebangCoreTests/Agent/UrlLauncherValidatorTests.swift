import Foundation
import Testing
@testable import ShebangCore

@Suite struct UrlLauncherValidatorTests {
    @Test func acceptsHttpAndHttps() throws {
        let https = try #require(UrlLauncherValidator.validatedWebURL("https://news.ycombinator.com"))
        #expect(https.scheme == "https")
        #expect(https.host == "news.ycombinator.com")
        #expect(UrlLauncherValidator.validatedWebURL("http://localhost:3000/dashboard")?.scheme == "http")
    }

    @Test(arguments: [
        "file:///System/Applications/Utilities/Terminal.app",
        "javascript:alert(1)",
        "open -a Terminal",
        "ftp://ftp.example.com",
        "data:text/html,<html></html>",
        "https://user:pass@example.com",
        "",
    ])
    func rejectsNonWebURLs(_ raw: String) {
        #expect(UrlLauncherValidator.validatedWebURL(raw) == nil)
    }

    @Test func extractsExplicitURLsAndStripsPunctuation() {
        let prompt = "Please navigate to https://github.com/nikhil-kunapareddy/Shebang and also check http://example.com/api."
        let urls = UrlLauncherValidator.extractWebURLs(prompt).map(\.absoluteString)
        #expect(urls == ["https://github.com/nikhil-kunapareddy/Shebang", "http://example.com/api"])
    }

    @Test func synthesizesSpotifySearchForMusicIntent() {
        let urls = UrlLauncherValidator.extractWebURLs("open spotify and play any song of aditya rikhari")
        #expect(urls.contains { ($0.host ?? "").contains("spotify.com") && $0.path.contains("search") })
    }

    @Test func synthesizesChainedPlatformSearch() {
        let urls = UrlLauncherValidator.extractWebURLs("open brave and search for youtube and search honey singh songs")
        #expect(urls.contains { ($0.host ?? "").contains("youtube.com") && ($0.query ?? "").contains("honey") })
    }

    @Test func bareDomainAndSearchEngines() {
        #expect(UrlLauncherValidator.extractWebURLs("go to wikipedia.org").first?.absoluteString == "https://wikipedia.org")
        #expect(UrlLauncherValidator.extractWebURLs("search for Adele on youtube").first?.absoluteString
            == "https://www.youtube.com/results?search_query=Adele")
        #expect(UrlLauncherValidator.extractWebURLs("google swift concurrency").first?.absoluteString
            == "https://www.google.com/search?q=swift%20concurrency")
    }

    @Test func plainInstructionsProduceNoURL() {
        #expect(UrlLauncherValidator.extractWebURLs("Calculate 450 * 12 + 85").isEmpty)
    }

    @Test(arguments: [
        ("search for quantum computing on google", "google.com", "quantum"),
        ("google current weather", "google.com", "weather"),
        ("open brave and search lion", "google.com", "lion"),
        ("search about lion", "google.com", "lion"),
        ("search lion in brave", "google.com", "lion"),
        ("open github.com", "github.com", ""),
        ("visit wikipedia.org", "wikipedia.org", ""),
    ])
    func synthesizesWebSearchesAndSites(goal: String, host: String, query: String) throws {
        let url = try #require(UrlLauncherValidator.extractWebURLs(goal).first)
        #expect(url.host?.contains(host) == true)
        if !query.isEmpty {
            #expect(url.query?.contains(query) == true)
        }
    }
}
