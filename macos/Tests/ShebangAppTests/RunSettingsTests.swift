import ShebangCore
import Testing
@testable import ShebangApp

@Suite struct RunSettingsTests {
    @Test func defaultsActForRealWithUnlimitedSteps() {
        let settings = RunSettings.fromEnvironment([:])
        #expect(!settings.isDryRun)
        #expect(settings.loopOptions.maxSteps == 0)
        #expect(settings.loopOptions.maxConsecutiveStalls == 15)
    }

    @Test(arguments: ["true", "TRUE", " True "])
    func dryRunOnlyWhenExplicitlyTrue(_ value: String) {
        #expect(RunSettings.fromEnvironment(["DRY_RUN": value]).isDryRun)
    }

    @Test(arguments: ["false", "", "1", "yes", "on", "truthy"])
    func anyOtherValueActsForReal(_ value: String) {
        #expect(!RunSettings.fromEnvironment(["DRY_RUN": value]).isDryRun)
    }

    @Test func maxStepsComeFromTheEnvironment() {
        #expect(RunSettings.fromEnvironment(["MAX_STEPS_PER_RUN": "25"]).loopOptions.maxSteps == 25)
        #expect(RunSettings.fromEnvironment(["MAX_STEPS_PER_RUN": " 7 "]).loopOptions.maxSteps == 7)
        #expect(RunSettings.fromEnvironment(["MAX_STEPS_PER_RUN": "0"]).loopOptions.maxSteps == 0)
    }

    @Test func invalidOrNegativeMaxStepsMeanUnlimited() {
        #expect(RunSettings.fromEnvironment(["MAX_STEPS_PER_RUN": "-4"]).loopOptions.maxSteps == 0)
        #expect(RunSettings.fromEnvironment(["MAX_STEPS_PER_RUN": "many"]).loopOptions.maxSteps == 0)
    }

    @Test func otherLoopDefaultsArePreserved() {
        let options = RunSettings.fromEnvironment(["DRY_RUN": "true", "MAX_STEPS_PER_RUN": "3"]).loopOptions
        #expect(options.actionTimeoutSeconds == AgentLoopOptions().actionTimeoutSeconds)
        #expect(options.escalateOnModelRiskScore == nil)
    }
}
