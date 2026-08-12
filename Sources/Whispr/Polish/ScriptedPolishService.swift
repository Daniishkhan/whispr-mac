import Foundation

/// Thread-safe canned service shared by unit tests and the CLI mock selftest.
actor ScriptedPolishService: PolishService {
    enum Step: Sendable {
        case response(PolishServiceResponse)
        case failure(PolishServiceError)
    }

    private var steps: [Step]
    private(set) var callCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func initial(transcript: String, glossary: [String]) async throws -> PolishServiceResponse {
        try next()
    }

    func resolve(
        transcript: String,
        answers: [PolishClarificationAnswer],
        skipped: [String],
        glossary: [String]
    ) async throws -> PolishServiceResponse {
        try next()
    }

    private func next() throws -> PolishServiceResponse {
        callCount += 1
        guard !steps.isEmpty else { throw PolishServiceError.decode }
        switch steps.removeFirst() {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }
}
