import AppKit
import ShebangCore

/// State of the goal prompt: goal text, status line, and voice input with live partial transcripts. A finished
/// transcript auto-submits after a short pause.
@MainActor
final class PromptViewModel: ObservableObject {
    static let idleHint = "Return to run · Esc to cancel"

    @Published var goal = ""
    @Published private(set) var status = StatusLine.neutral(idleHint)
    @Published private(set) var isListening = false
    @Published private(set) var targetDescription = TargetFormatting.promptDescription(nil)
    @Published private(set) var targetIcon: NSImage?
    @Published private(set) var isDryRun = false
    /// Bumped whenever the text field should take focus.
    @Published private(set) var focusRequest = 0

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var autoSubmitDelay: TimeInterval = 0.35

    let isVoiceAvailable: Bool
    private let speech: SpeechInput?
    private var acceptsInput = false
    private var speechTask: Task<Void, Never>?
    /// Invalidates callbacks from an abandoned recording.
    private var speechSession = 0

    init(speech: SpeechInput?) {
        self.speech = speech
        isVoiceAvailable = speech != nil
    }

    var canSubmit: Bool { acceptsInput && goal.nonBlank != nil }

    /// Resets the prompt for a newly captured target.
    func present(target: AppTarget?, icon: NSImage?, isDryRun: Bool) {
        abandonListening()
        goal = ""
        targetDescription = TargetFormatting.promptDescription(target)
        targetIcon = icon
        self.isDryRun = isDryRun
        status = isDryRun
            ? .warning("Dry run: actions are logged, not performed · Return to run")
            : .neutral(Self.idleHint)
        acceptsInput = true
        focusRequest += 1
    }

    /// Hides without reporting a cancel (the coordinator already knows).
    func dismiss() {
        abandonListening()
        acceptsInput = false
    }

    func submit() {
        guard acceptsInput, let text = goal.nonBlank else { return }
        acceptsInput = false
        abandonListening()
        onSubmit?(text)
    }

    func cancel() {
        guard acceptsInput else { return }
        acceptsInput = false
        abandonListening()
        onCancel?()
    }

    /// Shows a problem and keeps the prompt open for another attempt.
    func showError(_ message: String) {
        status = .error(message)
        acceptsInput = true
        focusRequest += 1
    }

    func toggleListening() {
        if isListening {
            // Stopping keeps what was heard; the recognizer then returns the final transcript.
            speech?.stopRecording()
            status = .info("Finishing…")
            return
        }
        guard acceptsInput else { return }
        guard let speech else {
            status = .error("Voice input is not available.")
            return
        }

        speechSession += 1
        let session = speechSession
        isListening = true
        status = .listening("Listening… speak your command (auto-submits when done)")

        let onPartial: @Sendable (String) -> Void = { [weak self] partial in
            Task { @MainActor in self?.applyPartial(partial, session: session) }
        }
        speechTask = Task { [weak self] in
            do {
                let transcript = try await speech.transcribe(onPartial: onPartial)
                self?.finishListening(transcript, session: session)
            } catch {
                self?.failListening(error, session: session)
            }
        }
    }

    private func applyPartial(_ partial: String, session: Int) {
        guard session == speechSession, isListening, let text = partial.nonBlank else { return }
        goal = text
    }

    private func finishListening(_ transcript: String, session: Int) {
        guard session == speechSession else { return }
        isListening = false
        speechTask = nil
        guard let text = transcript.nonBlank else {
            status = .error("No speech detected. Speak clearly and try again.")
            return
        }
        goal = text
        status = .success("“\(text)” — running…")

        let delay = autoSubmitDelay
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, self.speechSession == session, self.goal.nonBlank == text else { return }
            self.submit()
        }
    }

    private func failListening(_ error: Error, session: Int) {
        guard session == speechSession else { return }
        isListening = false
        speechTask = nil
        if error is CancellationError {
            status = .neutral("Voice recording cancelled.")
        } else {
            Log.speech.warning("Voice input failed: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
        }
    }

    private func abandonListening() {
        guard isListening || speechTask != nil else { return }
        speechSession += 1
        isListening = false
        speechTask?.cancel()
        speechTask = nil
    }
}
