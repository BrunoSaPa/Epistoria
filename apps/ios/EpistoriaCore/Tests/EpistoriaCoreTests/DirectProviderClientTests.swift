import Foundation
import XCTest
@testable import EpistoriaCore

private final class DirectProviderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class DirectProviderClientTests: XCTestCase {
    override func tearDown() {
        DirectProviderURLProtocol.handler = nil
        super.tearDown()
    }

    func testConnectionRunsBoundedGenerationWithoutModelDiscovery() async throws {
        var requestedPaths: [String] = []
        DirectProviderURLProtocol.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let object: [String: Any]
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/models"):
                object = ["data": [["id": "qwen3-vl:8b"]]]
            case ("POST", "/v1/chat/completions"):
                let body = try XCTUnwrap(Self.requestBody(request))
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(json["model"] as? String, "qwen3-vl:8b")
                XCTAssertEqual(json["stream"] as? Bool, false)
                XCTAssertEqual(json["max_tokens"] as? Int, 256)
                XCTAssertEqual(
                    (json["response_format"] as? [String: String])?["type"],
                    "json_object"
                )
                object = [
                    "id": "local-test",
                    "choices": [["message": ["content": #"{"status":"ok"}"#]]],
                ]
            default:
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"]
            )!
            return (response, try JSONSerialization.data(withJSONObject: object))
        }

        let result = try await client().testConnection(route: route(), apiKey: nil)

        XCTAssertEqual(result.verifiedModel, "qwen3-vl:8b")
        XCTAssertEqual(requestedPaths, ["/v1/chat/completions"])
    }

    func testEmptyModelAnswerIsNotTransportFailure() async throws {
        DirectProviderURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"]
            )!
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": ""]]],
            ])
            return (response, data)
        }

        do {
            _ = try await client().testConnection(route: route(), apiKey: nil)
            XCTFail("Expected the unavailable model to fail closed")
        } catch let error as DirectProviderError {
            XCTAssertEqual(error, .emptyOutput)
        }
    }

    func testProviderTimeoutHasSpecificRecoverableError() async throws {
        DirectProviderURLProtocol.handler = { _ in throw URLError(.timedOut) }

        do {
            _ = try await client().performText(
                ProviderTextRequest(prompt: "test", maximumOutputTokens: 1),
                route: route(),
                apiKey: nil
            )
            XCTFail("Expected timeout")
        } catch let error as DirectProviderError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testPrivateAddressPolicyRejectsLookalikeDomains() {
        for value in ["http://10.evil.example/v1", "http://192.168.evil.example", "http://172.16.999.1", "http://example.com", "https://user:secret@example.com", "https://example.com?key=secret"] {
            XCTAssertNil(AIProviderURLPolicy.normalized(value, adapter: .openAICompatible), value)
        }
        for value in ["http://10.0.0.1:11434/v1", "http://192.168.1.2", "http://172.31.0.1", "http://[::1]:11434", "http://[fd00::1]:11434", "http://host.local", "https://example.com/v1"] {
            XCTAssertNotNil(AIProviderURLPolicy.normalized(value, adapter: .openAICompatible), value)
        }
    }

    func testURLCancellationStaysCancellation() async throws {
        DirectProviderURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await client().testConnection(route: route(), apiKey: nil)
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTruncatedOutputIsNotAccepted() async throws {
        DirectProviderURLProtocol.handler = { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": "length", "message": ["content": "partial"]]],
            ])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        do {
            _ = try await client().testConnection(route: route(), apiKey: nil)
            XCTFail("Expected output limit")
        } catch let error as DirectProviderError { XCTAssertEqual(error, .outputLimitReached) }
    }

    func testOversizedResponseIsRejected() async throws {
        DirectProviderURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "8000001"])!, Data())
        }
        do {
            _ = try await client().testConnection(route: route(), apiKey: nil)
            XCTFail("Expected size limit")
        } catch let error as DirectProviderError { XCTAssertEqual(error, .invalidResponse) }
    }

    func testRedirectDelegateRejectsDestinationChange() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URLRequest(url: URL(string: "https://example.com/v1")!)
        let redirected = URLRequest(url: URL(string: "https://other.example/v1")!)
        let completion = expectation(description: "Redirect rejected")
        RejectProviderRedirects().urlSession(
            session, task: session.dataTask(with: original),
            willPerformHTTPRedirection: HTTPURLResponse(
                url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!,
            newRequest: redirected
        ) { request in
            XCTAssertNil(request)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 1)
    }

    func testUnannouncedOversizedResponseIsRejected() async throws {
        DirectProviderURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil)!, Data(repeating: 32, count: 8_000_001))
        }
        do {
            _ = try await client().testConnection(route: route(), apiKey: nil)
            XCTFail("Expected size limit")
        } catch let error as DirectProviderError { XCTAssertEqual(error, .invalidResponse) }
    }

    private func client() -> DirectProviderClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectProviderURLProtocol.self]
        return DirectProviderClient(session: URLSession(configuration: configuration))
    }

    private func route() -> AIProviderRouteSnapshot {
        AIProviderRouteSnapshot(
            profileId: UUID(),
            configurationRevisionId: UUID(),
            displayName: "Ollama",
            adapter: .openAICompatible,
            baseURL: "http://192.168.1.20:11434/v1",
            textModel: "qwen3-vl:8b",
            transcriptionModel: nil,
            capabilities: [.text, .vision],
            structuredOutput: true
        )
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            output.append(buffer, count: count)
        }
        return output
    }
}
