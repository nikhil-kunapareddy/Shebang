import Foundation
import GhostHandCore
import Testing
@testable import GhostHandPlatform

@Suite final class JSONLAuditLogTests {
    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostHand_AuditTests_\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func logFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func object(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func firstEntry() throws -> [String: Any] {
        let file = try #require(try logFiles().first)
        let line = try #require(try lines(of: file).first)
        return try object(line)
    }

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test func writesValidJSONLWithAllFields() async throws {
        let auditLog = JSONLAuditLog(directory: directory)
        await auditLog.log(AuditLogEntry(
            goal: "Search for quarterly reports",
            operation: .click,
            targetId: "e12",
            targetLabel: "Download PDF",
            targetRole: "AXButton",
            appProcess: "Finder",
            appTitle: "Documents Folder",
            decisionType: "auto",
            reason: "Benign navigation action"
        ))

        let files = try logFiles()
        #expect(files.count == 1)
        let fileLines = try lines(of: try #require(files.first))
        #expect(fileLines.count == 1)

        let json = try object(fileLines[0])
        #expect(json["goal"] as? String == "Search for quarterly reports")
        #expect(json["operation"] as? String == "Click")
        #expect(json["targetId"] as? String == "e12")
        #expect(json["targetLabel"] as? String == "Download PDF")
        #expect(json["targetRole"] as? String == "AXButton")
        #expect(json["appProcess"] as? String == "Finder")
        #expect(json["appTitle"] as? String == "Documents Folder")
        #expect(json["decisionType"] as? String == "auto")
        #expect(json["reason"] as? String == "Benign navigation action")
        #expect(json["timestamp"] is String)
    }

    @Test func sanitizesSensitiveData_neverWritesRawSecrets() async throws {
        let auditLog = JSONLAuditLog(directory: directory)
        await auditLog.log(AuditLogEntry(
            goal: "Use card 4532 0150 1234 5678 to purchase license vck_live_secret_key_abcdefg12345",
            operation: .typeText,
            targetId: "e5",
            targetLabel: "Card number 4532-0150-1234-5678",
            targetRole: "AXTextField",
            appProcess: "Safari",
            appTitle: "Checkout Portal — Bearer abcdefghijklmnopqrstuvwxyz",
            decisionType: "confirmed",
            reason: "User approved payment with key vck_live_key_9999"
        ))

        let content = try String(contentsOf: try #require(try logFiles().first), encoding: .utf8)
        #expect(!content.contains("4532 0150 1234 5678"))
        #expect(!content.contains("4532-0150-1234-5678"))
        #expect(!content.contains("vck_live_secret_key"))
        #expect(!content.contains("vck_live_key"))
        #expect(!content.contains("abcdefghijklmnopqrstuvwxyz"))
        #expect(content.contains("[REDACTED_CARD]"))
        #expect(content.contains("[REDACTED_KEY]"))
        #expect(content.contains("Bearer [REDACTED]"))
    }

    @Test func nilFieldsAreOmitted() async throws {
        let auditLog = JSONLAuditLog(directory: directory)
        await auditLog.log(AuditLogEntry(goal: "wait", operation: .wait, appProcess: "Notes", decisionType: "auto"))

        let json = try firstEntry()
        for key in ["targetId", "targetLabel", "targetRole", "reason"] {
            #expect(json[key] == nil, "\(key) should be omitted")
        }
        #expect(json["goal"] as? String == "wait")
        #expect(json["appTitle"] as? String == "")
    }

    @Test func timestampIsISO8601InUTCWithFractionalSeconds() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000.25)
        let auditLog = JSONLAuditLog(directory: directory)
        await auditLog.log(AuditLogEntry(timestamp: timestamp, operation: .done))

        let json = try firstEntry()
        let raw = try #require(json["timestamp"] as? String)
        #expect(raw.hasSuffix("Z"))

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try #require(parser.date(from: raw))
        #expect(abs(parsed.timeIntervalSince(timestamp)) < 0.001)
    }

    @Test func entriesGoToDailyFilesNamedByUTCDate() async throws {
        let auditLog = JSONLAuditLog(directory: directory)
        await auditLog.log(AuditLogEntry(timestamp: Self.date("2026-01-02T23:30:00Z"), operation: .click))
        await auditLog.log(AuditLogEntry(timestamp: Self.date("2026-01-02T00:05:00Z"), operation: .scrollDown))
        await auditLog.log(AuditLogEntry(timestamp: Self.date("2026-01-03T00:00:01Z"), operation: .done))

        let files = try logFiles()
        #expect(files.map(\.lastPathComponent) == ["audit-2026-01-02.jsonl", "audit-2026-01-03.jsonl"])
        #expect(try lines(of: files[0]).count == 2)
        #expect(try lines(of: files[1]).count == 1)
        #expect(auditLog.fileURL(for: Self.date("2026-01-02T12:00:00Z")).lastPathComponent == "audit-2026-01-02.jsonl")
    }

    @Test func concurrentWritesAreSerialized() async throws {
        let auditLog = JSONLAuditLog(directory: directory)
        let timestamp = Self.date("2026-05-05T10:00:00Z")
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    await auditLog.log(AuditLogEntry(
                        timestamp: timestamp, goal: "goal \(index) " + String(repeating: "x", count: 500), operation: .click))
                }
            }
        }

        let fileLines = try lines(of: try #require(try logFiles().first))
        #expect(fileLines.count == 50)
        let goals = try Set(fileLines.map { try object($0)["goal"] as? String ?? "" })
        #expect(goals.count == 50)
    }

    @Test func createsDirectoryAndPrivateFile() async throws {
        let auditLog = JSONLAuditLog(directory: directory)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)

        await auditLog.log(AuditLogEntry(operation: .click))
        let file = try #require(try logFiles().first)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func unwritableDirectory_isLoggedNotThrown() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)

        let auditLog = JSONLAuditLog(directory: blocker.appendingPathComponent("audit"))
        await auditLog.log(AuditLogEntry(operation: .click)) // must return normally
        #expect(try logFiles().isEmpty)
    }
}
