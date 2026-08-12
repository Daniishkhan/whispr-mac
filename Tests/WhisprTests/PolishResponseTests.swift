import XCTest
@testable import Whispr

final class PolishResponseTests: XCTestCase {
    func testOKContractReturnsRewrite() throws {
        XCTAssertEqual(try PolishResponseParser.parse(#"{"status":"ok","rewrite":"Fix the login page."}"#),
                       .ok(rewrite: "Fix the login page."))
    }

    func testUnclearCleansAndCapsQuestions() throws {
        XCTAssertEqual(
            try PolishResponseParser.parse(#"{"status":"unclear","draft":"Draft","questions":[" first ","","second","third","fourth"]}"#),
            .unclear(draft: "Draft", questions: ["first", "second", "third"])
        )
    }

    func testUnclearWithoutQuestionsUsesDraft() throws {
        XCTAssertEqual(try PolishResponseParser.parse(#"{"status":"unclear","draft":"Best draft","questions":[]}"#),
                       .ok(rewrite: "Best draft"))
    }

    func testUnclearWithoutDraftOrQuestionsFails() {
        XCTAssertThrowsError(try PolishResponseParser.parse(#"{"status":"unclear","questions":[]}"#)) {
            XCTAssertEqual($0 as? PolishServiceError, .unusableQuestions)
        }
    }

    func testUnknownAndEmptyContractValuesFail() {
        XCTAssertThrowsError(try PolishResponseParser.parse(#"{"status":"ok","rewrite":""}"#)) {
            XCTAssertEqual($0 as? PolishServiceError, .emptyRewrite)
        }
        XCTAssertThrowsError(try PolishResponseParser.parse(#"{"status":"other","rewrite":"text"}"#)) {
            XCTAssertEqual($0 as? PolishServiceError, .decode)
        }
    }

    func testPlaintextFallsBackToRewriteButValidNonContractJSONFails() throws {
        XCTAssertEqual(try PolishResponseParser.parse("Use TypeScript."), .ok(rewrite: "Use TypeScript."))
        XCTAssertThrowsError(try PolishResponseParser.parse(#"{"rewrite":"missing status"}"#)) {
            XCTAssertEqual($0 as? PolishServiceError, .decode)
        }
    }

    func testSingleJSONFenceIsTolerated() throws {
        XCTAssertEqual(try PolishResponseParser.parse("```json\n{\"status\":\"ok\",\"rewrite\":\"Done.\"}\n```"),
                       .ok(rewrite: "Done."))
    }
}
