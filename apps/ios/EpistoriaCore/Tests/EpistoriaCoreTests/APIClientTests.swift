import Foundation
import XCTest
@testable import EpistoriaCore

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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

final class APIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testBootstrapPreservesVersionedBasePath() async throws {
        let ownerId = UUID()
        let deviceId = UUID()
        let token = String(repeating: "t", count: 43)
        MockURLProtocol.handler = { request in
            let valid = request.url?.path == "/v1/auth/bootstrap"
                && request.httpMethod == "POST"
                && request.value(forHTTPHeaderField: "x-bootstrap-secret") == "a-secure-bootstrap-secret-32-bytes"
                && request.value(forHTTPHeaderField: "authorization") == nil
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: valid ? 201 : 418,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"]
            )!
            let data = try JSONSerialization.data(withJSONObject: [
                "ownerId": ownerId.uuidString.lowercased(),
                "deviceId": deviceId.uuidString.lowercased(),
                "token": token,
            ])
            return (response, data)
        }
        let client = EpistoriaAPIClient(
            baseURL: URL(string: "https://sync.example.test/v1")!,
            session: session()
        )
        let credentials = try await client.bootstrap(
            ownerId: ownerId,
            deviceId: deviceId,
            bootstrapSecret: "a-secure-bootstrap-secret-32-bytes"
        )
        XCTAssertEqual(credentials, DeviceCredentials(ownerId: ownerId, deviceId: deviceId, token: token))
    }

    func testEncryptedOutboxSynchronizesThroughWireContract() async throws {
        let ownerId = UUID()
        let deviceId = UUID()
        let token = String(repeating: "s", count: 43)
        var acceptedMutation: [String: Any]?
        MockURLProtocol.handler = { request in
            let responseData: Data
            let status: Int
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/sync/push"):
                guard request.value(forHTTPHeaderField: "authorization") == "Bearer \(token)" else {
                    return try Self.jsonResponse(request, status: 431, object: ["error": "auth"])
                }
                guard let body = Self.requestBody(request) else {
                    return try Self.jsonResponse(request, status: 432, object: ["error": "body"])
                }
                guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      (object["wireVersion"] as? NSNumber)?.intValue == 1
                else {
                    return try Self.jsonResponse(request, status: 433, object: ["error": "version"])
                }
                guard let mutations = object["mutations"] as? [[String: Any]],
                      let mutation = mutations.first,
                      let mutationId = mutation["mutationId"] as? String,
                      mutation["envelope"] is [String: Any]
                else {
                    return try Self.jsonResponse(request, status: 434, object: ["error": "mutation"])
                }
                acceptedMutation = mutation
                status = 201
                responseData = try JSONSerialization.data(withJSONObject: [
                    "wireVersion": 1,
                    "results": [[
                        "mutationId": mutationId,
                        "entityId": mutation["entityId"] as Any,
                        "status": "ACCEPTED",
                        "revision": 1,
                        "sequence": "1",
                        "conflictId": NSNull(),
                    ]],
                    "serverSequence": "1",
                ])
            case ("GET", "/v1/sync/pull"):
                guard request.url?.query?.contains("after=0") == true else {
                    return try Self.jsonResponse(request, status: 400, object: ["error": "bad cursor"])
                }
                guard let mutation = acceptedMutation else {
                    return try Self.jsonResponse(request, status: 409, object: ["error": "missing push"])
                }
                status = 200
                responseData = try JSONSerialization.data(withJSONObject: [
                    "wireVersion": 1,
                    "changes": [[
                        "sequence": "1",
                        "mutationId": mutation["mutationId"] as Any,
                        "entityId": mutation["entityId"] as Any,
                        "entityType": mutation["entityType"] as Any,
                        "operation": mutation["operation"] as Any,
                        "revision": 1,
                        "parentId": mutation["parentId"] ?? NSNull(),
                        "relationIds": mutation["relationIds"] as Any,
                        "clientModifiedAt": mutation["clientModifiedAt"] as Any,
                        "changedAt": "2026-08-11T12:00:00.000Z",
                        "envelope": mutation["envelope"] as Any,
                    ]],
                    "nextSequence": "1",
                    "latestSequence": "1",
                    "hasMore": false,
                ])
            case ("GET", "/v1/sync/conflicts"):
                status = 200
                responseData = try JSONSerialization.data(withJSONObject: ["conflicts": []])
            default:
                return try Self.jsonResponse(request, status: 404, object: ["error": "wrong path"])
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"]
            )!
            return (response, responseData)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountKey = Data(0 ..< 32)
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("sync.sqlite"),
            key: Data(repeating: 7, count: 32)
        )
        let noteId = UUID()
        _ = try await database.saveLocal(
            id: noteId,
            entityType: .note,
            content: try CanonicalJSON.encode(NotePayload(title: "Wire contract note")),
            search: SearchDocument(title: "Wire contract note", body: "")
        )
        let api = EpistoriaAPIClient(
            baseURL: URL(string: "https://sync.example.test/v1/")!,
            credentials: DeviceCredentials(ownerId: ownerId, deviceId: deviceId, token: token),
            session: session()
        )
        let engine = SyncEngine(
            accountId: ownerId,
            accountKey: accountKey,
            database: database,
            api: api
        )

        let report = try await engine.synchronize()
        let pending = try await database.pendingMutations()
        let stored = try await database.entity(id: noteId)
        XCTAssertEqual(report.pushedMutations, 1)
        XCTAssertEqual(report.finalSequence, "1")
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(stored?.syncState, .synced)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonResponse(
        _ request: URLRequest,
        status: Int,
        object: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["content-type": "application/json"]
        )!
        return (response, try JSONSerialization.data(withJSONObject: object))
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
            if count < 0 { return nil }
            if count == 0 { break }
            output.append(buffer, count: count)
        }
        return output
    }
}
