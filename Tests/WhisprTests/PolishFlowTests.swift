import XCTest
@testable import Whispr

final class PolishFlowTests: XCTestCase {
    func testOKPathUsesOneCall() async {
        let service = ScriptedPolishService(steps: [.response(.ok(rewrite: "Polished"))])
        let flow = PolishFlowController(service: service)

        let result = await flow.start(transcript: "raw", glossary: [])

        XCTAssertEqual(result, .ready(text: "Polished", provenance: .polished, warning: nil))
        let calls = await service.callCount
        XCTAssertEqual(calls, 1)
    }

    func testInitialFailureUsesRawTranscript() async {
        let service = ScriptedPolishService(steps: [.failure(.httpStatus(401))])
        let flow = PolishFlowController(service: service)

        let result = await flow.start(transcript: "raw", glossary: [])

        guard case .ready(let text, let provenance, let warning) = result else {
            return XCTFail("Expected raw fallback")
        }
        XCTAssertEqual(text, "raw")
        XCTAssertEqual(provenance, .raw)
        XCTAssertTrue(warning?.contains("Polish failed") == true)
    }

    func testUnclearThenResolutionUsesExactlyTwoCalls() async {
        let service = ScriptedPolishService(steps: [
            .response(.unclear(draft: "Draft", questions: ["Which item?"])),
            .response(.ok(rewrite: "Resolved")),
        ])
        let flow = PolishFlowController(service: service)

        let initial = await flow.start(transcript: "raw", glossary: [])
        XCTAssertEqual(initial, .clarification(draft: "Draft", questions: ["Which item?"]))
        let resolved = await flow.resolve(answers: ["the cache"])
        XCTAssertEqual(resolved, .ready(text: "Resolved", provenance: .polished, warning: nil))
        let calls = await service.callCount
        XCTAssertEqual(calls, 2)
    }

    func testAllSkippedUsesDraftWithoutSecondCall() async {
        let service = ScriptedPolishService(steps: [
            .response(.unclear(draft: "Draft", questions: ["Which item?"])),
        ])
        let flow = PolishFlowController(service: service)

        _ = await flow.start(transcript: "raw", glossary: [])
        let result = await flow.resolve(answers: [""])

        XCTAssertEqual(result, .ready(
            text: "Draft",
            provenance: .polished,
            warning: "No clarification answers were provided; using the best-effort polish."
        ))
        let calls = await service.callCount
        XCTAssertEqual(calls, 1)
    }

    func testAllSkippedWithoutDraftUsesRawWithoutSecondCall() async {
        let service = ScriptedPolishService(steps: [
            .response(.unclear(draft: nil, questions: ["Which item?"])),
        ])
        let flow = PolishFlowController(service: service)

        _ = await flow.start(transcript: "raw", glossary: [])
        let result = await flow.resolve(answers: [""])

        XCTAssertEqual(result, .ready(
            text: "raw",
            provenance: .raw,
            warning: "No clarification answers were provided; using the raw transcript."
        ))
        let calls = await service.callCount
        XCTAssertEqual(calls, 1)
    }

    func testResolutionFailureWithoutDraftUsesRawProvenance() async {
        let service = ScriptedPolishService(steps: [
            .response(.unclear(draft: nil, questions: ["Which item?"])),
            .failure(.timeout),
        ])
        let flow = PolishFlowController(service: service)

        _ = await flow.start(transcript: "raw", glossary: [])
        let result = await flow.resolve(answers: ["cache"])

        guard case .ready(let text, let provenance, let warning) = result else {
            return XCTFail("Expected raw fallback")
        }
        XCTAssertEqual(text, "raw")
        XCTAssertEqual(provenance, .raw)
        XCTAssertTrue(warning?.contains("Could not apply clarification answers") == true)
        let calls = await service.callCount
        XCTAssertEqual(calls, 2)
    }

    func testRepeatedUnclearWithoutDraftUsesRawProvenance() async {
        let service = ScriptedPolishService(steps: [
            .response(.unclear(draft: nil, questions: ["Which item?"])),
            .response(.unclear(draft: nil, questions: ["Again?"])),
        ])
        let flow = PolishFlowController(service: service)

        _ = await flow.start(transcript: "raw", glossary: [])
        let result = await flow.resolve(answers: ["cache"])

        XCTAssertEqual(result, .ready(
            text: "raw",
            provenance: .raw,
            warning: PolishServiceError.repeatedUnclear.localizedDescription
        ))
        let calls = await service.callCount
        XCTAssertEqual(calls, 2)
    }

    func testPasteRequiresSuccessfulActivationAndOriginalFrontmostTarget() {
        XCTAssertTrue(AppState.canPasteIntoTarget(
            activationSucceeded: true,
            targetIsTerminated: false,
            targetProcessIdentifier: 100,
            frontmostProcessIdentifier: 100
        ))
        XCTAssertFalse(AppState.canPasteIntoTarget(
            activationSucceeded: false,
            targetIsTerminated: false,
            targetProcessIdentifier: 100,
            frontmostProcessIdentifier: 100
        ))
        XCTAssertFalse(AppState.canPasteIntoTarget(
            activationSucceeded: true,
            targetIsTerminated: true,
            targetProcessIdentifier: 100,
            frontmostProcessIdentifier: 100
        ))
        XCTAssertFalse(AppState.canPasteIntoTarget(
            activationSucceeded: true,
            targetIsTerminated: false,
            targetProcessIdentifier: 100,
            frontmostProcessIdentifier: 200
        ))
    }

    func testMissingAnswerIsRecordedAsSkipped() async {
        let service = RecordingPolishService()
        let flow = PolishFlowController(service: service)

        _ = await flow.start(transcript: "raw", glossary: [])
        _ = await flow.resolve(answers: ["cache"])

        let skipped = await service.skipped
        XCTAssertEqual(skipped, ["Permanent?"])
    }

    func testSecondUnclearPrefersSecondDraft() async {
        let service = ScriptedPolishService(steps: [
            .response(.unclear(draft: "First draft", questions: ["Which item?"])),
            .response(.unclear(draft: "Second draft", questions: ["Again?"])),
        ])
        let flow = PolishFlowController(service: service)

        _ = await flow.start(transcript: "raw", glossary: [])
        let result = await flow.resolve(answers: ["cache"])

        XCTAssertEqual(result, .ready(
            text: "Second draft",
            provenance: .polished,
            warning: PolishServiceError.repeatedUnclear.localizedDescription
        ))
        let calls = await service.callCount
        XCTAssertEqual(calls, 2)
    }

    func testResolutionFailurePreservesFirstDraft() async {
        let service = ScriptedPolishService(steps: [
            .response(.unclear(draft: "First draft", questions: ["Which item?"])),
            .failure(.timeout),
        ])
        let flow = PolishFlowController(service: service)

        _ = await flow.start(transcript: "raw", glossary: [])
        let result = await flow.resolve(answers: ["cache"])

        guard case .ready(let text, let provenance, let warning) = result else {
            return XCTFail("Expected a usable fallback")
        }
        XCTAssertEqual(text, "First draft")
        XCTAssertEqual(provenance, .polished)
        XCTAssertTrue(warning?.contains("Could not apply clarification answers") == true)
        let calls = await service.callCount
        XCTAssertEqual(calls, 2)
    }

    func testCancellationSuppressesLateResult() async {
        let service = DelayedPolishService()
        let flow = PolishFlowController(service: service)
        let task = Task { await flow.start(transcript: "raw", glossary: []) }
        await service.waitUntilStarted()
        await flow.cancel()
        await service.finish()

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }
}

private actor RecordingPolishService: PolishService {
    private(set) var skipped: [String] = []

    func initial(transcript: String, glossary: [String]) async throws -> PolishServiceResponse {
        .unclear(draft: "Draft", questions: ["Which item?", "Permanent?"])
    }

    func resolve(transcript: String, answers: [PolishClarificationAnswer], skipped: [String], glossary: [String]) async throws -> PolishServiceResponse {
        self.skipped = skipped
        return .ok(rewrite: "Resolved")
    }
}

private actor DelayedPolishService: PolishService {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func initial(transcript: String, glossary: [String]) async throws -> PolishServiceResponse {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return .ok(rewrite: "late")
    }

    func resolve(transcript: String, answers: [PolishClarificationAnswer], skipped: [String], glossary: [String]) async throws -> PolishServiceResponse {
        .ok(rewrite: "unused")
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
