import Foundation

/// AppKit-independent controller for one dictation's at-most-two paid calls.
actor PolishFlowController {
    private let service: any PolishService
    private var generation = 0
    private var pending: Pending?

    private struct Pending: Sendable {
        let rawTranscript: String
        let glossary: [String]
        let draft: String?
        let questions: [String]
    }

    init(service: any PolishService) {
        self.service = service
    }

    func start(transcript: String, glossary: [String]) async -> PolishFlowResult {
        generation += 1
        let requestGeneration = generation
        pending = nil

        do {
            let response = try await service.initial(transcript: transcript, glossary: glossary)
            guard requestGeneration == generation else { return .cancelled }
            switch response {
            case .ok(let rewrite):
                return .ready(text: rewrite, provenance: .polished, warning: nil)
            case .unclear(let draft, let questions):
                pending = Pending(rawTranscript: transcript, glossary: glossary, draft: draft, questions: questions)
                return .clarification(draft: draft, questions: questions)
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard requestGeneration == generation else { return .cancelled }
            return .ready(text: transcript, provenance: .raw, warning: polishWarning(for: error, fallback: true))
        }
    }

    /// Applies non-empty answers and records all blank answers as deliberate skips.
    func resolve(answers: [String]) async -> PolishFlowResult {
        guard let pending else {
            return .ready(text: "", provenance: .raw, warning: "No clarification is pending.")
        }
        let requestGeneration = generation
        let pairs = zip(pending.questions, answers)
        let answered = pairs.compactMap { question, answer -> PolishClarificationAnswer? in
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : PolishClarificationAnswer(question: question, answer: trimmed)
        }
        let skipped = pending.questions.enumerated().compactMap { index, question in
            index < answers.count && !answers[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : question
        }

        // The all-skipped short circuit must never incur a second request.
        guard !answered.isEmpty else {
            self.pending = nil
            if let draft = pending.draft {
                return .ready(text: draft, provenance: .polished, warning: "No clarification answers were provided; using the best-effort polish.")
            }
            return .ready(text: pending.rawTranscript,
                          provenance: .raw,
                          warning: "No clarification answers were provided; using the raw transcript.")
        }

        self.pending = nil
        do {
            let response = try await service.resolve(
                transcript: pending.rawTranscript,
                answers: answered,
                skipped: skipped,
                glossary: pending.glossary
            )
            guard requestGeneration == generation else { return .cancelled }
            switch response {
            case .ok(let rewrite):
                return .ready(text: rewrite, provenance: .polished, warning: nil)
            case .unclear(let draft, _):
                let text = draft ?? pending.draft ?? pending.rawTranscript
                let provenance: PolishOutputProvenance = (draft ?? pending.draft) == nil ? .raw : .polished
                return .ready(
                    text: text,
                    provenance: provenance,
                    warning: PolishServiceError.repeatedUnclear.localizedDescription
                )
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard requestGeneration == generation else { return .cancelled }
            let text = pending.draft ?? pending.rawTranscript
            return .ready(
                text: text,
                provenance: pending.draft == nil ? .raw : .polished,
                warning: polishWarning(for: error, fallback: false)
            )
        }
    }

    func cancel() {
        generation += 1
        pending = nil
    }

    private func polishWarning(for error: Error, fallback: Bool) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return fallback
            ? "Polish failed — using the raw transcript. \(detail)"
            : "Could not apply clarification answers — using the best available draft. \(detail)"
    }
}
