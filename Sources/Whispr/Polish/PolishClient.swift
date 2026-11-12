import Foundation

struct PolishClient: PolishService, Sendable {
    private let configuration: PolishConfiguration
    private let session: URLSession

    init(configuration: PolishConfiguration, session: URLSession? = nil) throws {
        guard Self.validatedBaseURL(configuration.baseURL) != nil else {
            throw PolishServiceError.invalidURL
        }
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 45
            sessionConfiguration.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    static func validatedBaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return nil }
        return url
    }

    func initial(transcript: String, glossary: [String]) async throws -> PolishServiceResponse {
        try await request(system: PolishPrompt.initialSystem,
                          user: PolishPrompt.initialPayload(
                            transcript: transcript,
                            glossary: glossary,
                            targetApp: configuration.targetApp
                          ))
    }

    func resolve(
        transcript: String,
        answers: [PolishClarificationAnswer],
        skipped: [String],
        glossary: [String]
    ) async throws -> PolishServiceResponse {
        try await request(system: PolishPrompt.resolutionSystem,
                          user: PolishPrompt.resolutionPayload(
                            transcript: transcript,
                            answers: answers,
                            skipped: skipped,
                            glossary: glossary,
                            targetApp: configuration.targetApp
                          ))
    }

    private func request(system: String, user: String) async throws -> PolishServiceResponse {
        guard let baseURL = Self.validatedBaseURL(configuration.baseURL) else {
            throw PolishServiceError.invalidURL
        }
        let normalizedBaseURL: URL
        if baseURL.absoluteString.hasSuffix("/") {
            guard let trimmed = URL(string: String(baseURL.absoluteString.dropLast())) else {
                throw PolishServiceError.invalidURL
            }
            normalizedBaseURL = trimmed
        } else {
            normalizedBaseURL = baseURL
        }
        let endpoint = normalizedBaseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatCompletionsRequest(
            model: configuration.model,
            reasoningEffort: configuration.reasoningEffort.rawValue,
            stream: false,
            responseFormat: .init(type: "json_object"),
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ]
        ))

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PolishServiceError.transport("The endpoint returned no HTTP response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw PolishServiceError.httpStatus(http.statusCode)
            }
            let decoded: ChatCompletionsResponse
            do {
                decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
            } catch {
                throw PolishServiceError.decode
            }
            guard let content = decoded.choices.first?.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PolishServiceError.emptyRewrite
            }
            return try PolishResponseParser.parse(content)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw PolishServiceError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as PolishServiceError {
            throw error
        } catch {
            throw PolishServiceError.transport(error.localizedDescription)
        }
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct ResponseFormat: Encodable { let type: String }
    struct Message: Encodable { let role: String; let content: String }

    let model: String
    let reasoningEffort: String
    let stream: Bool
    let responseFormat: ResponseFormat
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case reasoningEffort = "reasoning_effort"
        case stream
        case responseFormat = "response_format"
        case messages
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}
