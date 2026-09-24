import Foundation
import ShebangCore
import ShebangPlatform

enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case accessibility, screenRecording, microphone, speechRecognition, apiKey

    var id: String { rawValue }

    var pane: Permissions.Pane? {
        switch self {
        case .accessibility: return .accessibility
        case .screenRecording: return .screenRecording
        case .microphone: return .microphone
        case .speechRecognition: return .speechRecognition
        case .apiKey: return nil
        }
    }
}

struct PermissionStatus: Equatable {
    var accessibility = false
    var screenRecording = false
    var microphone = false
    var speechRecognition = false
    var apiKey: CredentialCache.Source = .none
    var hotkeyListening = false

    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: return accessibility
        case .screenRecording: return screenRecording
        case .microphone: return microphone
        case .speechRecognition: return speechRecognition
        case .apiKey: return apiKey != .none
        }
    }
}

struct PermissionRow: Identifiable, Equatable {
    var kind: PermissionKind
    var title: String
    var detail: String
    var isRequired: Bool
    var isGranted: Bool
    var stateText: String
    var actionTitle: String

    var id: PermissionKind { kind }
}

/// System-facing side of the status window (a seam so tests never touch TCC).
@MainActor
protocol PermissionActions: AnyObject {
    func promptAccessibility()
    func requestScreenRecording()
    func requestMicrophone() async -> Bool
    func requestSpeechRecognition() async -> Bool
    func openSettings(_ pane: Permissions.Pane)
}

@MainActor
final class SystemPermissionActions: PermissionActions {
    func promptAccessibility() { Permissions.promptForAccessibility() }
    func requestScreenRecording() { Permissions.requestScreenRecording() }
    func requestMicrophone() async -> Bool { await Permissions.requestMicrophone() }
    func requestSpeechRecognition() async -> Bool { await Permissions.requestSpeechRecognition() }
    func openSettings(_ pane: Permissions.Pane) { Permissions.openSystemSettings(pane) }
}

/// Status & Permissions window. Polled by its window controller while open.
@MainActor
final class PermissionsViewModel: ObservableObject {
    @Published private(set) var status: PermissionStatus

    var onSetAPIKey: (() -> Void)?

    private let actions: PermissionActions
    private let statusProvider: () -> PermissionStatus
    /// The system prompts for Accessibility and Screen Recording appear once per app identity; after the first try,
    /// the button opens System Settings instead.
    private var prompted: Set<PermissionKind> = []

    init(actions: PermissionActions, statusProvider: @escaping () -> PermissionStatus) {
        self.actions = actions
        self.statusProvider = statusProvider
        status = statusProvider()
    }

    var rows: [PermissionRow] { PermissionKind.allCases.map(row) }

    var isReady: Bool { status.accessibility && status.apiKey != .none }

    var summary: String {
        if !status.accessibility { return "Accessibility access is required." }
        if status.apiKey == .none { return "Add your AI Gateway API key to start." }
        return "Ready. Press ⌃⌘ in any app."
    }

    var hotkeyText: String {
        status.hotkeyListening
            ? "⌃⌘ hotkey is listening."
            : "⌃⌘ hotkey starts automatically once Accessibility is granted."
    }

    func refresh() {
        let latest = statusProvider()
        if latest != status { status = latest }
    }

    func perform(_ kind: PermissionKind) {
        switch kind {
        case .apiKey:
            onSetAPIKey?()
        case .accessibility:
            promptOnceThenOpenSettings(kind) { $0.promptAccessibility() }
        case .screenRecording:
            promptOnceThenOpenSettings(kind) { $0.requestScreenRecording() }
        case .microphone:
            requestThenOpenSettings(kind) { await $0.requestMicrophone() }
        case .speechRecognition:
            requestThenOpenSettings(kind) { await $0.requestSpeechRecognition() }
        }
    }

    private func promptOnceThenOpenSettings(_ kind: PermissionKind, prompt: (PermissionActions) -> Void) {
        if status.isGranted(kind) || prompted.contains(kind) {
            kind.pane.map(actions.openSettings)
        } else {
            prompted.insert(kind)
            prompt(actions)
        }
        refresh()
    }

    /// Microphone and speech report denial synchronously, so a refused request falls through to System Settings.
    private func requestThenOpenSettings(_ kind: PermissionKind, request: @escaping (PermissionActions) async -> Bool) {
        guard !status.isGranted(kind) else {
            kind.pane.map(actions.openSettings)
            return
        }
        let actions = self.actions
        Task { [weak self] in
            if !(await request(actions)) {
                kind.pane.map(actions.openSettings)
            }
            self?.refresh()
        }
    }

    private func row(_ kind: PermissionKind) -> PermissionRow {
        let granted = status.isGranted(kind)
        switch kind {
        case .accessibility:
            return PermissionRow(
                kind: kind, title: "Accessibility",
                detail: "Read and operate the target app, and listen for the ⌃⌘ hotkey.",
                isRequired: true, isGranted: granted, stateText: granted ? "Granted" : "Not granted",
                actionTitle: granted ? "Open Settings…" : "Grant Access…")
        case .screenRecording:
            return PermissionRow(
                kind: kind, title: "Screen Recording",
                detail: "On-device OCR fallback for apps that expose few accessibility controls.",
                isRequired: false, isGranted: granted, stateText: granted ? "Granted" : "Not granted",
                actionTitle: granted ? "Open Settings…" : "Allow…")
        case .microphone:
            return PermissionRow(
                kind: kind, title: "Microphone",
                detail: "Voice input from the prompt's mic button.",
                isRequired: false, isGranted: granted, stateText: granted ? "Granted" : "Not granted",
                actionTitle: granted ? "Open Settings…" : "Allow…")
        case .speechRecognition:
            return PermissionRow(
                kind: kind, title: "Speech Recognition",
                detail: "Transcribes voice input, on this Mac when supported.",
                isRequired: false, isGranted: granted, stateText: granted ? "Granted" : "Not granted",
                actionTitle: granted ? "Open Settings…" : "Allow…")
        case .apiKey:
            let state: String
            switch status.apiKey {
            case .none: state = "Not set"
            case .environment: state = "From environment"
            case .keychain: state = "In Keychain"
            }
            return PermissionRow(
                kind: kind, title: "AI Gateway API key",
                detail: "Lets Shebang reach the Jev model on Vercel AI Gateway.",
                isRequired: true, isGranted: granted, stateText: state,
                actionTitle: granted ? "Change…" : "Set API Key…")
        }
    }
}
