import Foundation
import Security
import Testing
@testable import GhostHandPlatform

private final class InMemoryKeychainBackend: KeychainBackend {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private var items: [Key: String] = [:]
    var readError: Error?

    func read(service: String, account: String) throws -> String? {
        if let readError { throw readError }
        return items[Key(service: service, account: account)]
    }

    func write(_ value: String, service: String, account: String) throws {
        items[Key(service: service, account: account)] = value
    }

    func delete(service: String, account: String) throws {
        items[Key(service: service, account: account)] = nil
    }

    func stored(service: String, account: String) -> String? {
        items[Key(service: service, account: account)]
    }
}

@Suite struct KeychainCredentialStoreTests {
    private let backend = InMemoryKeychainBackend()

    private func makeStore(environment: [String: String] = [:], service: String = "svc", account: String = "acct")
        -> KeychainCredentialStore
    {
        KeychainCredentialStore(service: service, account: account, environment: environment, backend: backend)
    }

    @Test func SP02_roundTrip_saveAndRetrieve() throws {
        let store = makeStore()
        let key = "vck_test_roundtrip_" + UUID().uuidString
        try store.setAPIKey(key)

        #expect(store.hasKey)
        #expect(store.apiKey() == key)

        try store.deleteAPIKey()
        #expect(store.apiKey() == nil)
        #expect(!store.hasKey)
    }

    @Test func SP02_environmentVariable_takesPrecedenceOverKeychain() throws {
        let envKey = "vck_env_override_" + UUID().uuidString
        let store = makeStore(environment: ["AI_GATEWAY_API_KEY": envKey])
        try store.setAPIKey("vck_cred_manager_" + UUID().uuidString)

        #expect(store.apiKey() == envKey)
    }

    @Test func blankEnvironmentVariable_fallsBackToKeychain() throws {
        let store = makeStore(environment: ["AI_GATEWAY_API_KEY": "   \n"])
        try store.setAPIKey("vck_stored")
        #expect(store.apiKey() == "vck_stored")
    }

    @Test func environmentValueIsTrimmed() {
        let store = makeStore(environment: ["AI_GATEWAY_API_KEY": "  vck_env  \n"])
        #expect(store.apiKey() == "vck_env")
        #expect(store.hasKey)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func emptyKey_isRejected(_ key: String) {
        let store = makeStore()
        #expect(throws: CredentialStoreError.emptyKey) { try store.setAPIKey(key) }
        #expect(!store.hasKey)
    }

    @Test func savedKeyIsTrimmedAndScopedToServiceAndAccount() throws {
        let store = makeStore(service: "com.example.a", account: "KEY")
        try store.setAPIKey("  vck_trimmed  ")
        #expect(backend.stored(service: "com.example.a", account: "KEY") == "vck_trimmed")
        #expect(makeStore(service: "com.example.b", account: "KEY").apiKey() == nil)
    }

    @Test func deletingMissingKey_succeeds() throws {
        try makeStore().deleteAPIKey()
    }

    @Test func keychainReadFailure_returnsNilInsteadOfThrowing() {
        backend.readError = CredentialStoreError.keychain(status: errSecInteractionNotAllowed)
        let store = makeStore()
        #expect(store.apiKey() == nil)
        #expect(!store.hasKey)
    }

    @Test func defaultsMatchContract() {
        let store = KeychainCredentialStore(environment: [:])
        #expect(store.service == "com.ghosthand.mac")
        #expect(store.account == "AI_GATEWAY_API_KEY")
    }

    /// Touches the real login Keychain; run with `GHOSTHAND_KEYCHAIN_TESTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GHOSTHAND_KEYCHAIN_TESTS"] == "1"))
    func realKeychainRoundTrip() throws {
        let store = KeychainCredentialStore(
            service: "com.ghosthand.mac.tests.\(UUID().uuidString)", account: "AI_GATEWAY_API_KEY", environment: [:])
        defer { try? store.deleteAPIKey() }

        let key = "vck_keychain_test_" + UUID().uuidString
        try store.setAPIKey(key)
        #expect(store.apiKey() == key)

        try store.setAPIKey(key + "_updated")
        #expect(store.apiKey() == key + "_updated")

        try store.deleteAPIKey()
        #expect(store.apiKey() == nil)
    }
}
