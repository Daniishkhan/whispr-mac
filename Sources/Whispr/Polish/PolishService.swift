import Foundation

protocol PolishService: Sendable {
    func initial(transcript: String, glossary: [String]) async throws -> PolishServiceResponse
    func resolve(
        transcript: String,
        answers: [PolishClarificationAnswer],
        skipped: [String],
        glossary: [String]
    ) async throws -> PolishServiceResponse
}
