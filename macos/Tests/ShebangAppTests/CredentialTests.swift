import ShebangCore
import Testing
@testable import ShebangApp

@Suite @MainActor struct CredentialCacheTests {
    @Test func readsTheStoreOnce() {
        let store = FakeCredentialStore(stored: "test-key-123")
        let cache = CredentialCache(store: store, environment: { [:] })
        #expect(cache.apiKey == "test-key-123")
        #expect(cache.hasKey)
        #expect(cache.source == .keychain)
        #expect(store.readCount == 1)

        store.stored = "test-key-456"
        #expect(cache.apiKey == "test-key-123")
        cache.reload()
        #expect(cache.apiKey == "test-key-456")
        #expect(store.readCount == 2)
    }

    @Test func environmentKeyIsReportedAsSuch() {
        let store = FakeCredentialStore()
        let cache = CredentialCache(store: store, environment: { ["AI_GATEWAY_API_KEY": "env-test-key"] })
        #expect(cache.source == .environment)
        #expect(cache.environmentKey == "env-test-key")
        #expect(store.readCount == 0)
    }

    @Test func blankEnvironmentValueIsIgnored() {
        let cache = CredentialCache(store: FakeCredentialStore(), environment: { ["AI_GATEWAY_API_KEY": "  "] })
        #expect(cache.environmentKey == nil)
        #expect(cache.source == .none)
        #expect(!cache.hasKey)
    }

    @Test func saveUpdatesTheCache() throws {
        let store = FakeCredentialStore()
        let cache = CredentialCache(store: store, environment: { [:] })
        #expect(cache.apiKey == nil)
        try cache.save("  test-key-789 ")
        #expect(store.stored == "test-key-789")
        #expect(cache.apiKey == "test-key-789")
        #expect(store.readCount == 1)
    }

    @Test func optionsPreferTheEnvironmentKey() {
        let cache = CredentialCache(store: FakeCredentialStore(stored: "keychain-test-key"), environment: { [:] })
        let fromEnvironment = cache.optionsWithKey(JevOptions(apiKey: "env-test-key"))
        #expect(fromEnvironment?.apiKey == "env-test-key")

        let fromKeychain = cache.optionsWithKey(JevOptions(apiKey: " "))
        #expect(fromKeychain?.apiKey == "keychain-test-key")
    }

    @Test func optionsAreNilWithoutAnyKey() {
        let cache = CredentialCache(store: FakeCredentialStore(), environment: { [:] })
        #expect(cache.optionsWithKey(JevOptions()) == nil)
    }
}

@Suite @MainActor struct APIKeyViewModelTests {
    private final class TesterLog: @unchecked Sendable {
        var keys: [String] = []
    }

    private func makeModel(
        stored: String? = nil,
        environment: [String: String] = [:],
        tester: @escaping (String) async throws -> String = { _ in "ok" }
    ) -> (APIKeyViewModel, FakeCredentialStore, CredentialCache) {
        let store = FakeCredentialStore(stored: stored)
        let cache = CredentialCache(store: store, environment: { environment })
        let model = APIKeyViewModel(credentials: cache, tester: tester)
        model.prepare(reason: .firstRun)
        return (model, store, cache)
    }

    @Test func prepareDescribesTheSituation() {
        let (model, _, _) = makeModel()
        #expect(model.headline == "Connect Shebang to Vercel AI Gateway")
        #expect(!model.hasExistingKey)
        #expect(!model.environmentOverride)
        #expect(model.placeholder == "Paste your AI Gateway API key")

        let (manual, _, _) = makeModel(stored: "test-key-123", environment: ["AI_GATEWAY_API_KEY": "env-test-key"])
        manual.prepare(reason: .manual)
        #expect(manual.headline == "AI Gateway API Key")
        #expect(manual.hasExistingKey)
        #expect(manual.environmentOverride)
        #expect(manual.placeholder.contains("replace"))
    }

    @Test func prepareClearsThePreviousForm() {
        let (model, _, _) = makeModel()
        model.keyText = "half typed"
        model.save()
        model.prepare(reason: .missingForRun)
        #expect(model.keyText.isEmpty)
        #expect(model.message == nil)
        #expect(model.explanation.contains("before it can run"))
    }

    @Test func emptyKeyIsRejected() {
        let (model, store, _) = makeModel()
        var saved = 0
        model.onSaved = { saved += 1 }
        model.keyText = "   "
        #expect(!model.save())
        #expect(model.message == .error("Please enter a valid API key before saving."))
        #expect(store.stored == nil)
        #expect(saved == 0)
    }

    @Test func saveStoresTheTrimmedKey() {
        let (model, store, cache) = makeModel()
        var saved = 0
        model.onSaved = { saved += 1 }
        model.keyText = "  test-key-123\n"
        #expect(model.save())
        #expect(store.stored == "test-key-123")
        #expect(cache.apiKey == "test-key-123")
        #expect(model.keyText.isEmpty)
        #expect(model.hasExistingKey)
        #expect(model.message?.tone == .success)
        #expect(saved == 1)
    }

    @Test func saveFailureIsShown() {
        let (model, store, _) = makeModel()
        store.saveError = TestError(message: "Keychain error -25308")
        model.keyText = "test-key-123"
        #expect(!model.save())
        #expect(model.message == .error("Failed to save key: Keychain error -25308"))
    }

    @Test func cancelReportsAndStopsTesting() {
        let (model, _, _) = makeModel()
        var cancelled = 0
        model.onCancel = { cancelled += 1 }
        model.cancel()
        #expect(cancelled == 1)
        #expect(!model.isTesting)
    }

    @Test func testNeedsAKey() {
        let (model, _, _) = makeModel()
        model.testConnection()
        #expect(model.message == .error("Enter an API key to test."))
        #expect(!model.isTesting)
    }

    @Test func testsTheEnteredKey() async {
        let log = TesterLog()
        let (model, _, _) = makeModel(stored: "saved-test-key") { key in
            log.keys.append(key)
            return "Jev reachable"
        }
        model.keyText = " typed-test-key "
        model.testConnection()
        #expect(model.isTesting)
        #expect(await waitUntil { !model.isTesting })
        #expect(log.keys == ["typed-test-key"])
        #expect(model.message == .success("Jev reachable"))
    }

    @Test func testsTheSavedKeyWhenTheFieldIsEmpty() async {
        let log = TesterLog()
        let (model, _, _) = makeModel(stored: "saved-test-key") { key in
            log.keys.append(key)
            return "Jev reachable"
        }
        model.testConnection()
        #expect(await waitUntil { !model.isTesting })
        #expect(log.keys == ["saved-test-key"])
    }

    @Test func testFailureIsShown() async {
        let (model, _, _) = makeModel(stored: "saved-test-key") { _ in
            throw TestError(message: "Authentication failed (HTTP 401): invalid key")
        }
        model.testConnection()
        #expect(await waitUntil { !model.isTesting })
        #expect(model.message == .error("Authentication failed (HTTP 401): invalid key"))
    }

    @Test func cancelledTestLeavesNoResult() async {
        let (model, _, _) = makeModel(stored: "saved-test-key") { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "late"
        }
        model.testConnection()
        model.cancelTest()
        #expect(!model.isTesting)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.message == .info("Testing connection…"))
    }
}
