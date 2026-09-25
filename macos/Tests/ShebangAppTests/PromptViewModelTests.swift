import ShebangCore
import Testing
@testable import ShebangApp

@MainActor
private final class PromptRecorder {
    var submitted: [String] = []
    var cancels = 0

    init(_ model: PromptViewModel) {
        model.onSubmit = { [unowned self] in submitted.append($0) }
        model.onCancel = { [unowned self] in cancels += 1 }
    }
}

@Suite @MainActor struct PromptViewModelTests {
    private func makeModel(speech: SpeechInput? = nil) -> (PromptViewModel, PromptRecorder) {
        let model = PromptViewModel(speech: speech)
        model.autoSubmitDelay = 0
        let recorder = PromptRecorder(model)
        model.present(target: Samples.safari, icon: nil, isDryRun: false)
        return (model, recorder)
    }

    @Test func presentResetsForTheTarget() {
        let (model, _) = makeModel()
        model.goal = "old goal"
        let focus = model.focusRequest
        model.present(target: Samples.notes, icon: nil, isDryRun: false)
        #expect(model.goal.isEmpty)
        #expect(model.targetDescription == "Target: Notes")
        #expect(model.status == .neutral(PromptViewModel.idleHint))
        #expect(model.focusRequest == focus + 1)
        #expect(!model.isDryRun)
    }

    @Test func dryRunIsFlagged() {
        let (model, _) = makeModel()
        model.present(target: nil, icon: nil, isDryRun: true)
        #expect(model.isDryRun)
        #expect(model.status.tone == .warning)
        #expect(model.targetDescription == "Target: Desktop")
    }

    @Test func submitSendsTheTrimmedGoalOnce() {
        let (model, recorder) = makeModel()
        model.goal = "  open notes and write hello  "
        #expect(model.canSubmit)
        model.submit()
        model.submit()
        #expect(recorder.submitted == ["open notes and write hello"])
        #expect(!model.canSubmit)
    }

    @Test func blankGoalsAreNotSubmitted() {
        let (model, recorder) = makeModel()
        model.goal = "   "
        #expect(!model.canSubmit)
        model.submit()
        #expect(recorder.submitted.isEmpty)
    }

    @Test func nothingIsSubmittedBeforeThePromptIsPresented() {
        let model = PromptViewModel(speech: nil)
        let recorder = PromptRecorder(model)
        model.goal = "search lion"
        model.submit()
        model.cancel()
        #expect(recorder.submitted.isEmpty)
        #expect(recorder.cancels == 0)
    }

    @Test func cancelReportsOnce() {
        let (model, recorder) = makeModel()
        model.cancel()
        model.cancel()
        #expect(recorder.cancels == 1)
        model.submit()
        #expect(recorder.submitted.isEmpty)
    }

    @Test func errorKeepsThePromptOpen() {
        let (model, recorder) = makeModel()
        model.goal = "do it"
        model.submit()
        model.showError("No app to control.")
        #expect(model.status == .error("No app to control."))
        model.submit()
        #expect(recorder.submitted == ["do it", "do it"])
    }

    @Test func dismissStopsAcceptingInput() {
        let (model, recorder) = makeModel()
        model.goal = "do it"
        model.dismiss()
        model.submit()
        model.cancel()
        #expect(recorder.submitted.isEmpty)
        #expect(recorder.cancels == 0)
    }

    @Test func micWithoutSpeechShowsAnError() {
        let (model, _) = makeModel()
        #expect(!model.isVoiceAvailable)
        model.toggleListening()
        #expect(model.status == .error("Voice input is not available."))
        #expect(!model.isListening)
    }

    @Test func transcriptFillsTheFieldAndAutoSubmits() async {
        let speech = FakeSpeech(partials: ["open", "open safari"], result: .success(" open safari "))
        let (model, recorder) = makeModel(speech: speech)
        model.toggleListening()
        #expect(model.isListening)
        #expect(model.status.tone == .listening)
        #expect(await waitUntil { recorder.submitted == ["open safari"] })
        #expect(model.goal == "open safari")
        #expect(!model.isListening)
    }

    @Test func partialsAppearLiveAndStopKeepsTheTranscript() async {
        let speech = FakeSpeech(partials: ["search", "search lion"], result: .success("search lion"), waitsForStop: true)
        let (model, recorder) = makeModel(speech: speech)
        model.toggleListening()
        #expect(await waitUntil { model.goal == "search lion" })
        #expect(model.isListening)

        model.toggleListening()
        #expect(speech.stopCalls == 1)
        #expect(await waitUntil { recorder.submitted == ["search lion"] })
    }

    @Test func emptyTranscriptAsksToTryAgain() async {
        let (model, recorder) = makeModel(speech: FakeSpeech(result: .success("  ")))
        model.toggleListening()
        #expect(await waitUntil { !model.isListening })
        #expect(model.status == .error("No speech detected. Speak clearly and try again."))
        #expect(recorder.submitted.isEmpty)
    }

    @Test func speechErrorsAreShown() async {
        let (model, recorder) = makeModel(speech: FakeSpeech(result: .failure(TestError(message: "No microphone."))))
        model.toggleListening()
        #expect(await waitUntil { !model.isListening })
        #expect(model.status == .error("No microphone."))
        #expect(recorder.submitted.isEmpty)
    }

    @Test func cancellingThePromptAbandonsRecording() async {
        let speech = FakeSpeech(partials: ["hel"], result: .success("hello"), waitsForStop: true)
        let (model, recorder) = makeModel(speech: speech)
        model.toggleListening()
        #expect(await waitUntil { model.goal == "hel" })
        model.cancel()
        #expect(!model.isListening)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.submitted.isEmpty)
        #expect(recorder.cancels == 1)
    }

    @Test func editingDuringTheAutoSubmitPauseCancelsIt() async {
        let speech = FakeSpeech(result: .success("open notes"))
        let (model, recorder) = makeModel(speech: speech)
        model.autoSubmitDelay = 0.1
        model.toggleListening()
        #expect(await waitUntil { model.goal == "open notes" && !model.isListening })
        model.goal = "open notes and write a list"
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(recorder.submitted.isEmpty)
    }
}

@Suite struct TargetFormattingTests {
    @Test func describesTargets() {
        #expect(TargetFormatting.promptDescription(nil) == "Target: Desktop")
        #expect(TargetFormatting.promptDescription(Samples.safari) == "Target: Safari — “Apply — Example Jobs”")
        #expect(TargetFormatting.promptDescription(Samples.notes) == "Target: Notes")
        var untitled = Samples.safari
        untitled.windowTitle = "  "
        #expect(TargetFormatting.appDescription(untitled) == "Safari")
    }
}
