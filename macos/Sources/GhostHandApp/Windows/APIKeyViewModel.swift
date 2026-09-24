import Foundation
import GhostHandCore

/// State of the API key window (port of ApiKeySetupDialog.xaml.cs, plus a connection test).
@MainActor
final class APIKeyViewModel: ObservableObject {
    enum Reason: Equatable {
        /// No key at launch.
        case firstRun
        /// A goal was submitted without a key.
        case missingForRun
        /// Opened from the menu or the status window.
        case manual
    }

    static let dashboardURL = URL(string: "https://vercel.com/dashboard")!

    @Published var keyText = ""
    @Published private(set) var message: StatusLine?
    @Published private(set) var isTesting = false
    @Published private(set) var reason: Reason = .manual
    @Published private(set) var hasExistingKey = false
    /// `AI_GATEWAY_API_KEY` is set in the environment (or `.env`) and wins over the Keychain.
    @Published private(set) var environmentOverride = false

    var onSaved: (() -> Void)?
    var onCancel: (() -> Void)?

    private let credentials: CredentialCache
    private let tester: (String) async throws -> String
    private var testTask: Task<Void, Never>?

    /// `tester` sends a diagnostic request with the given key and returns a one-line summary.
    init(credentials: CredentialCache, tester: @escaping (String) async throws -> String) {
        self.credentials = credentials
        self.tester = tester
    }

    var headline: String {
        reason == .manual ? "AI Gateway API Key" : "Connect GhostHand to Vercel AI Gateway"
    }

    var explanation: String {
        switch reason {
        case .missingForRun:
            return "GhostHand needs an API key before it can run. It uses the Jev model through Vercel AI Gateway."
        case .firstRun, .manual:
            return "GhostHand uses the Jev model through Vercel AI Gateway to decide each step."
        }
    }

    var placeholder: String {
        hasExistingKey ? "Enter a new key to replace the saved one" : "Paste your AI Gateway API key"
    }

    /// Resets the form each time the window opens.
    func prepare(reason: Reason) {
        cancelTest()
        self.reason = reason
        keyText = ""
        message = nil
        hasExistingKey = credentials.hasKey
        environmentOverride = credentials.environmentKey != nil
    }

    @discardableResult
    func save() -> Bool {
        guard let key = keyText.nonBlank else {
            message = .error("Please enter a valid API key before saving.")
            return false
        }
        do {
            try credentials.save(key)
        } catch {
            message = .error("Failed to save key: \(error.localizedDescription)")
            return false
        }
        cancelTest()
        keyText = ""
        hasExistingKey = true
        message = .success("Saved to Keychain.")
        onSaved?()
        return true
    }

    func cancel() {
        cancelTest()
        onCancel?()
    }

    /// Tests the key in the field, or the configured key when the field is empty.
    func testConnection() {
        guard let key = keyText.nonBlank ?? credentials.apiKey else {
            message = .error("Enter an API key to test.")
            return
        }
        testTask?.cancel()
        isTesting = true
        message = .info("Testing connection…")
        let tester = self.tester
        testTask = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await tester(key))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            self.isTesting = false
            self.testTask = nil
            switch result {
            case .success(let summary):
                self.message = .success(summary)
            case .failure(let error):
                self.message = .error(error.localizedDescription)
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
    }
}
