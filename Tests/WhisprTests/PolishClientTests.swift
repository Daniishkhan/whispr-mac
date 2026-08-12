import Foundation
import XCTest
@testable import Whispr

final class PolishClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.lastRequest = nil
        URLProtocolStub.lastRequestBody = nil
        super.tearDown()
    }

    func testInitialRequestHasContractShapeAndGlossary() async throws {
        URLProtocolStub.handler = { request in
            let response = #"{"choices":[{"message":{"content":"{\"status\":\"ok\",\"rewrite\":\"Fix login.\"}"}}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(response.utf8))
        }

        let client = try makeClient()
        let result = try await client.initial(transcript: "fix log in", glossary: ["TypeScript", "kubectl"])
        XCTAssertEqual(result, .ok(rewrite: "Fix login."))

        let request = try XCTUnwrap(URLProtocolStub.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(URLProtocolStub.lastRequestBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["reasoning_effort"] as? String, "high")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual((json["response_format"] as? [String: String])?["type"], "json_object")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let payloadData = try XCTUnwrap(messages.last?["content"]?.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        XCTAssertEqual(payload["transcript"] as? String, "fix log in")
        XCTAssertEqual(payload["glossary"] as? [String], ["TypeScript", "kubectl"])
    }

    func testHTTPStatusIsMapped() async throws {
        URLProtocolStub.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = try makeClient()
        do {
            _ = try await client.initial(transcript: "text", glossary: [])
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? PolishServiceError, .httpStatus(401))
        }
    }

    func testTimeoutIsMapped() async throws {
        URLProtocolStub.handler = { _ in throw URLError(.timedOut) }
        let client = try makeClient()
        do {
            _ = try await client.initial(transcript: "text", glossary: [])
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? PolishServiceError, .timeout)
        }
    }

    func testBaseURLValidationRejectsUnsafeURLs() {
        XCTAssertNotNil(PolishClient.validatedBaseURL("https://example.com/v1"))
        XCTAssertNil(PolishClient.validatedBaseURL("http://example.com/v1"))
        XCTAssertNil(PolishClient.validatedBaseURL("https://user:pass@example.com/v1"))
        XCTAssertNil(PolishClient.validatedBaseURL("https://example.com/v1?key=no"))
        XCTAssertNil(PolishClient.validatedBaseURL("https://example.com/v1#fragment"))
        XCTAssertNil(PolishClient.validatedBaseURL("https:///v1"))
    }

    private func makeClient() throws -> PolishClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return try PolishClient(
            configuration: PolishConfiguration(
                baseURL: "https://example.com/v1",
                model: "test-model",
                reasoningEffort: .high,
                apiKey: "test-key"
            ),
            session: URLSession(configuration: configuration)
        )
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var storedLastRequest: URLRequest?
    nonisolated(unsafe) private static var storedLastRequestBody: Data?

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    static var lastRequest: URLRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedLastRequest
        }
        set {
            lock.lock()
            storedLastRequest = newValue
            lock.unlock()
        }
    }

    static var lastRequestBody: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedLastRequestBody
        }
        set {
            lock.lock()
            storedLastRequestBody = newValue
            lock.unlock()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.lastRequest = request
            Self.lastRequestBody = Self.bodyData(for: request)
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer {
                stream.read($0.baseAddress!, maxLength: $0.count)
            }
            guard count >= 0 else {
                return nil
            }
            guard count > 0 else {
                return body
            }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}
