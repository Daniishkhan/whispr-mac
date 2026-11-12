import Foundation
import XCTest
@testable import Whispr

final class VocabularyTests: XCTestCase {

    private func project(_ name: String, spoken: [String], glossary: [String] = []) -> ProjectVocabulary {
        ProjectVocabulary(
            repository: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true),
            spoken: spoken,
            glossary: glossary
        )
    }

    // MARK: - Builder

    func testManualTermsComeFirstAndAutomaticTermsAreCounted() {
        let lists = VocabularyBuilder.build(
            manual: ["Deepgram"],
            learned: ["kubectl", "deepgram"],
            project: [project("app", spoken: ["AppState", "kubectl"], glossary: ["AppState.swift"])]
        )
        XCTAssertEqual(lists.keyterms, ["Deepgram", "kubectl", "AppState"])
        XCTAssertEqual(lists.automaticKeytermCount, 2)
        XCTAssertEqual(lists.glossary, ["Deepgram", "kubectl", "AppState.swift"])
    }

    func testAutomaticKeytermsCanBeLeftOutOfRecognitionOnly() {
        let lists = VocabularyBuilder.build(
            manual: ["Deepgram"],
            learned: ["kubectl"],
            project: [project("app", spoken: ["AppState"], glossary: ["AppState"])],
            automaticKeyterms: false
        )
        XCTAssertEqual(lists.keyterms, ["Deepgram"])
        XCTAssertEqual(lists.automaticKeytermCount, 0)
        XCTAssertEqual(lists.glossary, ["Deepgram", "kubectl", "AppState"])
    }

    func testAutomaticKeytermsStayInsideTheTokenBudget() {
        let manyNames = (0..<400).map { "VeryLongIdentifierNumber\($0)" }
        let lists = VocabularyBuilder.build(
            manual: [],
            learned: manyNames,
            project: [project("app", spoken: manyNames.map { $0 + "Type" })]
        )
        let estimate = lists.keyterms.reduce(0) { $0 + VocabularyBuilder.estimatedTokens($1) }
        XCTAssertLessThanOrEqual(estimate, VocabularyBuilder.keytermTokenBudget)
        XCTAssertLessThanOrEqual(lists.keyterms.count, VocabularyBuilder.maxKeyterms)
        XCTAssertGreaterThan(lists.keyterms.count, 10)
    }

    func testManualTermsAreNeverDroppedForTheBudget() {
        let manual = (0..<100).map { "ManualVocabularyTermNumber\($0)" }
        let lists = VocabularyBuilder.build(manual: manual, learned: ["kubectl"], project: [])
        XCTAssertEqual(Array(lists.keyterms.prefix(100)), manual)
        XCTAssertEqual(lists.automaticKeytermCount, 0)
    }

    func testMostLikelyProjectGetsTwoPlacesForEveryOneOfTheOthers() {
        XCTAssertEqual(
            VocabularyBuilder.weighted([["a1", "a2", "a3", "a4"], ["b1", "b2"], ["c1"]]),
            ["a1", "a2", "b1", "a3", "a4", "c1", "b2"]
        )
    }

    // MARK: - Harvester

    func testDeclaredNamesKeepDistinctiveNamesOnly() {
        let source = """
        final class AudioCapture {
            enum Phase { case idle }
            private enum CodingKeys: String, CodingKey { case id }
            func start() {}
            private func restartAfterConfigurationChange() async {}
        }
        public struct PolishFlowController {}
        def handle_event(self): pass
        export function renderPreview() {}
        const value = 1
        """
        let names = ProjectHarvester.declaredNames(in: source)
        XCTAssertEqual(names.types, ["AudioCapture", "PolishFlowController"])
        XCTAssertEqual(names.functions, ["restartAfterConfigurationChange", "handle_event", "renderPreview"])
    }

    func testUncommittedPathsSkipDeletionsAndFollowRenames() {
        let status = """
         M Sources/App/AppState.swift
        ?? Sources/App/New File.swift
         D Sources/App/Gone.swift
        R  Old.swift -> Sources/App/Renamed.swift
        ?? vendor/
        """
        XCTAssertEqual(ProjectHarvester.uncommittedPaths(fromStatus: status), [
            "Sources/App/AppState.swift",
            "Sources/App/New File.swift",
            "Sources/App/Renamed.swift",
        ])
    }

    func testOrdinaryFileNamesAreNotWorthBoosting() {
        XCTAssertTrue(ProjectHarvester.isDistinctiveFileStem("AudioCapture"))
        XCTAssertTrue(ProjectHarvester.isDistinctiveFileStem("train_gpt2"))
        XCTAssertFalse(ProjectHarvester.isDistinctiveFileStem("prepare"))
        XCTAssertFalse(ProjectHarvester.isDistinctiveFileStem("index"))
        XCTAssertFalse(ProjectHarvester.isDistinctiveFileStem(".gitignore"))
        XCTAssertFalse(ProjectHarvester.isDistinctiveFileStem("applicants-A-call-studio"))
    }

    // MARK: - Locator

    func testRepositoryRootIsFoundFromANestedFileAndNotOutsideARepository() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-locator-\(UUID().uuidString)", isDirectory: true)
        let nested = base.appendingPathComponent("repo/Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("repo/.git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let file = nested.appendingPathComponent("AppState.swift")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(
            ProjectLocator.repositoryRoot(containing: file)?.standardizedFileURL.path,
            base.appendingPathComponent("repo").standardizedFileURL.path
        )
        XCTAssertNil(ProjectLocator.repositoryRoot(containing: base))
    }
}
