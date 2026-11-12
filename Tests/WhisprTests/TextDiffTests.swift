import XCTest
@testable import Whispr

final class TextDiffTests: XCTestCase {

    /// Stands in for the system spell checker.
    private let dictionary: Set<String> = [
        "the", "use", "cube", "control", "to", "restart", "pods", "rust", "rest", "endpoint",
        "there", "their", "tests", "is", "are", "fix", "repair", "code", "cloud", "open",
        "in", "and", "then", "run", "get", "type", "script", "file", "check", "sequel", "query",
    ]
    private func isWord(_ word: String) -> Bool { dictionary.contains(word) }

    func testSubstitutionsIgnoreCaseAndPunctuation() {
        let changes = TextDiff.substitutions(
            from: "use cube control to restart the pods",
            to: "Use kubectl to restart the pods."
        )
        XCTAssertEqual(changes, [TextDiff.Change(from: "cube control", to: "kubectl")])
    }

    func testInsertionsAndDeletionsAreNotSubstitutions() {
        XCTAssertEqual(TextDiff.substitutions(from: "um fix the tests", to: "Fix the tests, then run them."), [])
    }

    func testNotableSubstitutionsKeepNamesAndDropGrammar() {
        let changes = TextDiff.notableSubstitutions(
            from: "there tests is in the rust endpoint and use sequel",
            to: "Their tests are in the REST endpoint and use SQL.",
            limit: 8,
            isDictionaryWord: isWord
        )
        XCTAssertEqual(changes, [
            TextDiff.Change(from: "rust", to: "REST"),
            TextDiff.Change(from: "sequel", to: "SQL"),
        ])
    }

    func testSpacingOnlyChangesAreNotNotable() {
        let changes = TextDiff.notableSubstitutions(
            from: "check the type script file",
            to: "Check the TypeScript file.",
            limit: 8,
            isDictionaryWord: isWord
        )
        XCTAssertEqual(changes, [])
    }

    func testNotableSubstitutionsRespectLimit() {
        let changes = TextDiff.notableSubstitutions(
            from: "use sequel then use rust",
            to: "use SQL then use REST",
            limit: 1,
            isDictionaryWord: isWord
        )
        XCTAssertEqual(changes, [TextDiff.Change(from: "sequel", to: "SQL")])
    }

    func testCorrectedTermsLearnsNamesNotRewording() {
        let terms = TextDiff.correctedTerms(
            from: "Open cloud code and fix the tests with cube control.",
            to: "Open Claude Code and repair the tests with kubectl.",
            isDictionaryWord: isWord
        )
        XCTAssertEqual(terms, ["Claude Code", "kubectl"])
    }

    func testCorrectedTermsKeepsOnlyTheNameFromALongerReplacement() {
        let terms = TextDiff.correctedTerms(
            from: "use the cube control",
            to: "run kubectl get",
            isDictionaryWord: isWord
        )
        XCTAssertEqual(terms, ["kubectl"])
    }

    func testTokensKeepCodePunctuation() {
        let changes = TextDiff.substitutions(
            from: "open app state dot swift",
            to: "Open `AppState.swift`."
        )
        XCTAssertEqual(changes, [TextDiff.Change(from: "app state dot swift", to: "AppState.swift")])
    }

    func testWordLooksLikeTerm() {
        XCTAssertTrue(TextDiff.wordLooksLikeTerm("TypeScript", isDictionaryWord: isWord))
        XCTAssertTrue(TextDiff.wordLooksLikeTerm("SQL", isDictionaryWord: isWord))
        XCTAssertTrue(TextDiff.wordLooksLikeTerm("gpt-5", isDictionaryWord: isWord))
        XCTAssertTrue(TextDiff.wordLooksLikeTerm("snake_case", isDictionaryWord: isWord))
        XCTAssertTrue(TextDiff.wordLooksLikeTerm("kubectl", isDictionaryWord: isWord))
        XCTAssertFalse(TextDiff.wordLooksLikeTerm("control", isDictionaryWord: isWord))
        XCTAssertFalse(TextDiff.wordLooksLikeTerm("Fix", isDictionaryWord: isWord))
        XCTAssertFalse(TextDiff.wordLooksLikeTerm("42", isDictionaryWord: isWord))
    }
}
