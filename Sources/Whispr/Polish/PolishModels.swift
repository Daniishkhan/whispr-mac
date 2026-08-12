import Foundation

/// The reasoning levels accepted by the configured Chat Completions endpoint.
enum PolishReasoningEffort: String, CaseIterable, Hashable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}

struct PolishConfiguration: Sendable {
    let baseURL: String
    let model: String
    let reasoningEffort: PolishReasoningEffort
    let apiKey: String
}

enum PolishServiceResponse: Equatable, Sendable {
    case ok(rewrite: String)
    case unclear(draft: String?, questions: [String])
}

struct PolishClarificationAnswer: Codable, Equatable, Sendable {
    let question: String
    let answer: String
}

/// Errors deliberately distinguish a cancelled request from a usable fallback.
enum PolishServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case transport(String)
    case timeout
    case httpStatus(Int)
    case decode
    case emptyRewrite
    case unusableQuestions
    case repeatedUnclear

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The LLM base URL must be an HTTPS URL without credentials, a query, or a fragment."
        case .transport(let message):
            return "Could not reach the LLM endpoint: \(message)"
        case .timeout:
            return "The LLM request timed out."
        case .httpStatus(let status):
            return "The LLM endpoint returned HTTP \(status)."
        case .decode:
            return "The LLM returned an invalid polish response."
        case .emptyRewrite:
            return "The LLM returned an empty rewrite."
        case .unusableQuestions:
            return "The LLM reported ambiguity without a usable draft or question."
        case .repeatedUnclear:
            return "The LLM needs more clarification; using the best available draft."
        }
    }
}

/// Identifies whether a ready result is an LLM-produced draft/rewrite or the
/// original raw transcript used as a fallback.
enum PolishOutputProvenance: Equatable, Sendable {
    case polished
    case raw
}

/// Result exposed by the flow controller, independent of AppKit.
enum PolishFlowResult: Equatable, Sendable {
    case ready(text: String, provenance: PolishOutputProvenance, warning: String?)
    case clarification(draft: String?, questions: [String])
    case cancelled
}

private struct PolishContractResponse: Decodable {
    let status: String?
    let rewrite: String?
    let draft: String?
    let questions: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case status, rewrite, draft, questions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        rewrite = try container.decodeIfPresent(String.self, forKey: .rewrite)
        draft = try container.decodeIfPresent(String.self, forKey: .draft)
        questions = try container.decodeIfPresent([JSONValue].self, forKey: .questions)
    }
}

/// Decodes the response taxonomy shared by initial and resolution requests.
enum PolishResponseParser {
    static func parse(_ text: String) throws -> PolishServiceResponse {
        let cleaned = stripSingleMarkdownFence(from: text)
        guard !cleaned.isEmpty else { throw PolishServiceError.emptyRewrite }

        let data = Data(cleaned.utf8)
        do {
            let contract = try JSONDecoder().decode(PolishContractResponse.self, from: data)
            guard let status = contract.status else { throw PolishServiceError.decode }
            switch status {
            case "ok":
                guard let rewrite = cleanedText(contract.rewrite) else {
                    throw PolishServiceError.emptyRewrite
                }
                return .ok(rewrite: rewrite)
            case "unclear":
                let questions = (contract.questions ?? [])
                    .compactMap(\.stringValue)
                    .compactMap(cleanedText)
                    .prefix(3)
                let draft = cleanedText(contract.draft)
                if !questions.isEmpty {
                    return .unclear(draft: draft, questions: Array(questions))
                }
                if let draft {
                    return .ok(rewrite: draft)
                }
                throw PolishServiceError.unusableQuestions
            default:
                throw PolishServiceError.decode
            }
        } catch let error as PolishServiceError {
            throw error
        } catch {
            // A valid JSON value that does not conform to the contract is a
            // failure. Only genuinely non-JSON text gets the plaintext fallback.
            if (try? JSONDecoder().decode(JSONValue.self, from: data)) != nil {
                throw PolishServiceError.decode
            }
            return .ok(rewrite: cleaned)
        }
    }

    private static func cleanedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripSingleMarkdownFence(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.hasPrefix("```") else { return cleaned }
        guard let firstNewline = cleaned.firstIndex(of: "\n"), cleaned.hasSuffix("```") else {
            return cleaned
        }
        // One outer markdown fence is transport decoration, not response text.
        cleaned = String(cleaned[cleaned.index(after: firstNewline)..<cleaned.index(cleaned.endIndex, offsetBy: -3)])
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Minimal Codable JSON representation used only to distinguish malformed JSON
/// from valid JSON that violates the response contract.
private indirect enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}
