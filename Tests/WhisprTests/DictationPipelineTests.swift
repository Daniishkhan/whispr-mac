import Foundation
import XCTest
@testable import Whispr

/// Small contracts between the stages of a dictation: what Deepgram's frames
/// mean, what the polish request carries, and what history keeps.
final class DictationPipelineTests: XCTestCase {

    // MARK: - Deepgram frames

    func testResultCarriesFromFinalizeFlag() {
        let frame = #"{"type":"Results","is_final":true,"speech_final":false,"from_finalize":true,"channel":{"alternatives":[{"transcript":"fix the tests"}]}}"#
        guard case .results(let isFinal, _, let transcript, let fromFinalize) = DeepgramMessage.parse(frame) else {
            return XCTFail("Expected a results frame")
        }
        XCTAssertTrue(isFinal)
        XCTAssertEqual(transcript, "fix the tests")
        XCTAssertTrue(fromFinalize)
    }

    func testOrdinaryResultIsNotFromFinalize() {
        let frame = #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"fix"}]}}"#
        guard case .results(_, _, _, let fromFinalize) = DeepgramMessage.parse(frame) else {
            return XCTFail("Expected a results frame")
        }
        XCTAssertFalse(fromFinalize)
    }

    // MARK: - Polish request

    private func payload(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testInitialPayloadNamesTheTargetApp() throws {
        let object = try payload(PolishPrompt.initialPayload(
            transcript: "fix log in",
            glossary: ["AppState.swift"],
            targetApp: "Terminal"
        ))
        XCTAssertEqual(object["transcript"] as? String, "fix log in")
        XCTAssertEqual(object["glossary"] as? [String], ["AppState.swift"])
        XCTAssertEqual(object["target_app"] as? String, "Terminal")
    }

    func testPayloadOmitsTargetAppWhenUnknown() throws {
        let object = try payload(PolishPrompt.initialPayload(transcript: "text", glossary: []))
        XCTAssertNil(object["target_app"])
    }

    func testResolutionPayloadKeepsAnswersAndTarget() throws {
        let object = try payload(PolishPrompt.resolutionPayload(
            transcript: "delete the temp thing",
            answers: [PolishClarificationAnswer(question: "Which?", answer: "the cache")],
            skipped: ["Permanently?"],
            glossary: [],
            targetApp: "Claude"
        ))
        XCTAssertEqual(object["skipped"] as? [String], ["Permanently?"])
        XCTAssertEqual((object["answered"] as? [[String: String]])?.first?["answer"], "the cache")
        XCTAssertEqual(object["target_app"] as? String, "Claude")
    }

    /// The model is handed a glossary and a target app; the instructions have
    /// to say what each is for, and both request types share one contract.
    func testSystemPromptsExplainTheirInputsAndShareTheContract() {
        for prompt in [PolishPrompt.initialSystem, PolishPrompt.resolutionSystem] {
            XCTAssertTrue(prompt.contains("\"glossary\""))
            XCTAssertTrue(prompt.contains("\"target_app\""))
            XCTAssertTrue(prompt.contains(#"{"status":"ok","rewrite":"#))
            XCTAssertTrue(prompt.contains(#"{"status":"unclear","draft":"#))
        }
    }

    // MARK: - Settings

    func testParseTermsTrimsDeduplicatesAndCaps() {
        XCTAssertEqual(
            SettingsStore.parseTerms("  kubectl \n\nKubectl\nPostgres\nAppState", limit: 2),
            ["kubectl", "Postgres"]
        )
    }

    // MARK: - History

    func testEntriesWrittenBeforeRawAndPolishedWereStoredStillLoad() throws {
        let legacy = #"[{"id":"BE1055F6-D378-4C95-AFBB-8912D33710A9","date":"2026-11-09T18:03:23Z","text":"hello"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([HistoryStore.Entry].self, from: Data(legacy.utf8))
        XCTAssertEqual(entries.first?.text, "hello")
        XCTAssertNil(entries.first?.raw)
        XCTAssertNil(entries.first?.timings)
    }

    func testEntryRoundTripsEveryStage() throws {
        let entry = HistoryStore.Entry(
            text: "Use kubectl.",
            raw: "use cube control",
            polished: "Use kubectl.",
            target: "Terminal",
            timings: HistoryStore.Timings(finishMs: 420, finishReason: "finalize", polishMs: 1_300)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HistoryStore.Entry.self, from: encoder.encode(entry))
        XCTAssertEqual(decoded.raw, "use cube control")
        XCTAssertEqual(decoded.polished, "Use kubectl.")
        XCTAssertEqual(decoded.target, "Terminal")
        XCTAssertEqual(decoded.timings, entry.timings)
    }
}
