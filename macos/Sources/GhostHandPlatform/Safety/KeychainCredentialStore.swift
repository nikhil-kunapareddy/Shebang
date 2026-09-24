import Foundation
import GhostHandCore
import Security

public enum CredentialStoreError: Error, LocalizedError, Equatable {
    case emptyKey
    case keychain(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "API key cannot be empty."
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error \(status): \(message)"
        }
    }
}

/// Stores the AI Gateway API key as a generic password in the login Keychain.
/// A non-empty `AI_GATEWAY_API_KEY` environment variable always wins.
public final class KeychainCredentialStore: CredentialStore {
    public static let environmentVariable = "AI_GATEWAY_API_KEY"

    public let service: String
    public let account: String
    private let environment: [String: String]
    private let backend: KeychainBackend

    public convenience init(
        service: String = "com.ghosthand.mac",
        account: String = "AI_GATEWAY_API_KEY",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(service: service, account: account, environment: environment, backend: SecItemKeychainBackend())
    }

    init(service: String, account: String, environment: [String: String], backend: KeychainBackend) {
        self.service = service
        self.account = account
        self.environment = environment
        self.backend = backend
    }

    public func apiKey() -> String? {
        if let envKey = environment[Self.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envKey.isEmpty {
            return envKey
        }

        do {
            let stored = try backend.read(service: service, account: account)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stored?.isEmpty == false ? stored : nil
        } catch {
            Log.safety.warning("Failed to read API key from Keychain: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public var hasKey: Bool {
        apiKey() != nil
    }

    public func setAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialStoreError.emptyKey }
        try backend.write(trimmed, service: service, account: account)
        Log.safety.info("API key saved to Keychain")
    }

    public func deleteAPIKey() throws {
        try backend.delete(service: service, account: account)
        Log.safety.info("API key removed from Keychain")
    }
}

/// Seam over SecItem so unit tests never touch (or prompt for) the real Keychain.
protocol KeychainBackend: AnyObject {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
    /// Succeeds when the item doesn't exist.
    func delete(service: String, account: String) throws
}

final class SecItemKeychainBackend: KeychainBackend {
    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status: status)
        }
    }

    func write(_ value: String, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "GhostHand AI Gateway API key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: status)
        }
    }
}
