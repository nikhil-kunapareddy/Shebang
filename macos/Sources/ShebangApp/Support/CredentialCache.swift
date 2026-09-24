import Foundation
import ShebangCore

/// Keeps the API key in memory after one read at launch: a Keychain access prompt raised while handling the hotkey
/// would steal focus from the target app.
@MainActor
final class CredentialCache {
    enum Source: Equatable {
        case none, environment, keychain
    }

    static let environmentVariable = "AI_GATEWAY_API_KEY"

    private let store: CredentialStore
    private let environment: () -> [String: String]
    private var cachedKey: String?
    private var loaded = false

    init(store: CredentialStore, environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }) {
        self.store = store
        self.environment = environment
    }

    /// Reads the store (environment first, then Keychain) and caches the result.
    func reload() {
        cachedKey = store.apiKey()?.nonBlank
        loaded = true
    }

    var apiKey: String? {
        if !loaded { reload() }
        return cachedKey
    }

    var hasKey: Bool { apiKey != nil }

    /// Where the effective key comes from, without touching the Keychain once loaded.
    var source: Source {
        if environmentKey != nil { return .environment }
        return apiKey != nil ? .keychain : .none
    }

    var environmentKey: String? {
        environment()[Self.environmentVariable]?.nonBlank
    }

    func save(_ key: String) throws {
        try store.setAPIKey(key)
        cachedKey = key.nonBlank
        loaded = true
    }

    /// `options` with its API key filled from the cache when the environment didn't supply one; nil when no key exists.
    func optionsWithKey(_ options: JevOptions) -> JevOptions? {
        var resolved = options
        if resolved.apiKey?.nonBlank == nil {
            resolved.apiKey = apiKey
        }
        return resolved.apiKey?.nonBlank == nil ? nil : resolved
    }
}
