import Foundation
import Testing
@testable import ShebangCore

@Suite struct JevReviewRegressionTests {
    private func response(_ json: String) throws -> EvaluateResponse {
        try JSONDecoder().decode(EvaluateResponse.self, from: Data(json.utf8))
    }

    @Test func outOfRangeProbabilitiesAreUnparseable() throws {
        let huge = try response(#"{"answers":{"goalAchieved":{"probability":1e17}}}"#)
        #expect(huge.booleanAnswer("goalAchieved") == nil)

        let choice = try response(#"{"answers":{"nextAction":{"choice":"wait","probabilities":{"wait":1e300}}}}"#)
        #expect(choice.choiceAnswer("nextAction")?.confidence == 0)
    }

    @Test func confidenceLookupIgnoresCase() throws {
        let answer = try response(#"{"answers":{"nextAction":{"choice":"CLICK:e1","probabilities":{"click:e1":0.8}}}}"#)
        #expect(answer.choiceAnswer("nextAction")?.confidence == 0.8)
    }
}
