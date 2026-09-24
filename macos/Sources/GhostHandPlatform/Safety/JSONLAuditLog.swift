import Foundation
import GhostHandCore

/// Appends one JSON object per line to `audit-YYYY-MM-DD.jsonl` (UTC date, as in the Windows build).
/// Free-text fields are scrubbed with `SecretSanitizer`; nil fields are omitted; writes are serialized.
public final class JSONLAuditLog: AuditLog {
    public let directory: URL
    private let queue = DispatchQueue(label: "com.ghosthand.mac.audit-log")
    private let encoder: JSONEncoder

    public init(directory: URL = PlatformInfo.applicationSupportDirectory.appendingPathComponent("audit")) {
        self.directory = directory

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(JSONLAuditLog.timestampString(date))
        }
        self.encoder = encoder

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.safety.warning("Failed to create audit log directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func log(_ entry: AuditLogEntry) async {
        let sanitized = Self.sanitized(entry)
        let fileURL = fileURL(for: sanitized.timestamp)

        let line: Data
        do {
            line = try encoder.encode(sanitized) + Data("\n".utf8)
        } catch {
            Log.safety.error("Failed to encode audit entry: \(error.localizedDescription, privacy: .public)")
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [directory] in
                do {
                    try Self.append(line, to: fileURL, directory: directory)
                    Log.safety.debug("Audit: \(sanitized.decisionType, privacy: .public) \(sanitized.operation.rawValue, privacy: .public)")
                } catch {
                    Log.safety.error("Failed to write audit entry to \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume()
            }
        }
    }

    public func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("audit-\(Self.dayString(date)).jsonl")
    }

    static func sanitized(_ entry: AuditLogEntry) -> AuditLogEntry {
        var copy = entry
        copy.goal = SecretSanitizer.sanitize(entry.goal)
        copy.targetLabel = entry.targetLabel.map { SecretSanitizer.sanitize($0) }
        copy.reason = entry.reason.map { SecretSanitizer.sanitize($0) }
        copy.appTitle = SecretSanitizer.sanitize(entry.appTitle)
        return copy
    }

    static func timestampString(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func append(_ data: Data, to fileURL: URL, directory: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Goals and window titles can be personal; keep the file private to the user.
            guard fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
