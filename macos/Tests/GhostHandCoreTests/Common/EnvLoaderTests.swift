import Foundation
import Testing
@testable import GhostHandCore

/// Serialized because the tests mutate the process environment.
@Suite(.serialized) final class EnvLoaderTests {
    private let directory: URL
    private let prefix = "GH_ENVTEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))_"

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostHandEnvLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix(prefix) {
            unsetenv(key)
        }
    }

    private func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[prefix + name]
    }

    @discardableResult
    private func write(_ contents: String, to subdirectory: String? = nil) throws -> URL {
        var folder = directory
        if let subdirectory {
            folder = folder.appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let file = folder.appendingPathComponent(".env")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func parse_handlesCommentsQuotesAndBlankLines() {
        let pairs = EnvLoader.parse("""
        \u{FEFF}# comment
        A=1

          B = spaced value  \r
        C="double quoted"
        D='single quoted'
        E="unbalanced
        F=x=y=z
        =no-key
        no separator
        G=
        H="
        """)
        #expect(pairs.map(\.key) == ["A", "B", "C", "D", "E", "F", "G", "H"])
        #expect(pairs.map(\.value) == ["1", "spaced value", "double quoted", "single quoted", "\"unbalanced", "x=y=z", "", "\""])
    }

    @Test func load_setsVariablesFromFile() throws {
        let file = try write("""
        \(prefix)KEY=value
        \(prefix)QUOTED="hello world"
        """)

        #expect(EnvLoader.load(searchPaths: [file]) == file)
        #expect(env("KEY") == "value")
        #expect(env("QUOTED") == "hello world")
    }

    @Test func load_neverOverridesExistingValues() throws {
        setenv(prefix + "EXISTING", "from-shell", 1)
        setenv(prefix + "EMPTY", "", 1)
        let file = try write("""
        \(prefix)EXISTING=from-file
        \(prefix)EMPTY=filled
        """)

        EnvLoader.load(searchPaths: [file])

        #expect(env("EXISTING") == "from-shell")
        // Like Windows, an empty value counts as unset.
        #expect(env("EMPTY") == "filled")
    }

    @Test func load_usesFirstExistingFileInSearchOrder() throws {
        let missing = directory.appendingPathComponent("missing/.env")
        let first = try write("\(prefix)ORDER=first", to: "first")
        let second = try write("\(prefix)ORDER=second\n\(prefix)ONLY_SECOND=1", to: "second")

        #expect(EnvLoader.load(searchPaths: [missing, first, second]) == first)
        #expect(env("ORDER") == "first")
        #expect(env("ONLY_SECOND") == nil)
    }

    @Test func load_acceptsDirectories() throws {
        let file = try write("\(prefix)DIR=yes", to: "project")

        #expect(EnvLoader.load(searchPaths: [directory.appendingPathComponent("project", isDirectory: true)]) == file)
        #expect(env("DIR") == "yes")
    }

    @Test func load_withoutAnyFile_returnsNil() {
        #expect(EnvLoader.load(searchPaths: [directory.appendingPathComponent("nothing/.env")]) == nil)
        #expect(EnvLoader.load(searchPaths: []) == nil)
    }

    @Test func defaultSearchPaths_followContractOrder() throws {
        let paths = EnvLoader.defaultSearchPaths
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        #expect(paths.first?.standardizedFileURL == cwd.appendingPathComponent(".env").standardizedFileURL)

        let support = try #require(paths.dropFirst().first)
        #expect(support.path.hasSuffix("Library/Application Support/GhostHand/.env"))
        #expect(paths.allSatisfy { $0.lastPathComponent == ".env" })
        #expect(Set(paths.map(\.standardizedFileURL.path)).count == paths.count)
    }
}
