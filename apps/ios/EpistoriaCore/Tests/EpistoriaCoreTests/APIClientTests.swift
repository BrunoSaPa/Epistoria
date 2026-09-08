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

    func testAssetDownloadUsesAuthenticatedDescriptorAndReportsReceivedBytes() async throws {
        let id = UUID()
        let content = Data(repeating: 7, count: 70_000)
        let progress = DownloadProgressRecorder()
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/download") == true {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
                return try Self.jsonResponse(request, status: 200, object: [
                    "assetId": id.uuidString, "encryptedByteSize": String(content.count),
                    "url": "https://objects.example.test/original", "expiresInSeconds": 60,
                ])
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, content)
        }
        let api = EpistoriaAPIClient(baseURL: URL(string: "https://sync.example.test/v1")!,
            credentials: DeviceCredentials(ownerId: UUID(), deviceId: UUID(), token: "synthetic-token"), session: session())
        let downloaded = try await api.downloadAsset(id: id, maximumBytes: content.count) { received, total in
            await progress.record(received, total)
        }
        XCTAssertEqual(downloaded, content)
        let updates = await progress.values
        XCTAssertEqual(updates.first?.0, 0)
        XCTAssertEqual(updates.last?.0, Int64(content.count))
        XCTAssertTrue(updates.allSatisfy { $0.0 <= $0.1 })
    }

    func testAssetDownloadRejectsOversizedAndTruncatedBodies() async throws {
        for count in [3, 5] {
            let id = UUID()
            MockURLProtocol.handler = { request in
                if request.url?.path.hasSuffix("/download") == true {
                    return try Self.jsonResponse(request, status: 200, object: [
                        "assetId": id.uuidString, "encryptedByteSize": "4",
                        "url": "https://objects.example.test/original", "expiresInSeconds": 60,
                    ])
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(repeating: 0, count: count))
            }
            let api = authenticatedAssetClient()
            do {
                _ = try await api.downloadAsset(id: id, maximumBytes: 4)
                XCTFail("Invalid size was accepted")
            } catch let error as APIClientError {
                XCTAssertEqual(error, count > 4 ? .assetTooLarge : .invalidResponse)
            }
        }
    }

    func testAssetDownloadCancellationDoesNotBecomeTransportFailure() async throws {
        let id = UUID()
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/download") == true {
                return try Self.jsonResponse(request, status: 200, object: [
                    "assetId": id.uuidString, "encryptedByteSize": "4",
                    "url": "https://objects.example.test/original", "expiresInSeconds": 60,
                ])
            }
            throw URLError(.cancelled)
        }
        let api = authenticatedAssetClient()
        do {
            _ = try await api.downloadAsset(id: id)
            XCTFail("Cancelled download returned")
        } catch is CancellationError {
            // Expected: the foreground UI can report that remaining work was stopped.
        }
    }

    func testAssetCacheVerifiesBytesAndSurvivesManagerRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID()
        let accountKey = Data(repeating: 3, count: 32)
        let assetKey = Data(repeating: 8, count: 32)
        let plaintext = Data("synthetic offline original".utf8)
        let encrypted = try AssetCrypto().encrypt(plaintext, key: assetKey)
        let database = try SQLCipherDatabase(url: directory.appendingPathComponent("test.sqlite"), key: accountKey)
        let store = EpistoriaStore(database: database)
        let id = try await store.save(payload: AssetPayload(mimeType: "text/plain",
            plaintextByteSize: Int64(plaintext.count), encryptedByteSize: Int64(encrypted.count),
            dedupeTag: EntityCrypto().dedupeTag(plaintext: plaintext, accountKey: accountKey, accountId: account),
            assetKey: Base64URL.encode(assetKey), originalFilename: "synthetic.txt"))
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/download") == true {
                return try Self.jsonResponse(request, status: 200, object: [
                    "assetId": id.uuidString, "encryptedByteSize": String(encrypted.count),
                    "url": "https://objects.example.test/original", "expiresInSeconds": 60,
                ])
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, encrypted)
        }
        let api = authenticatedAssetClient()
        let assetDirectory = directory.appendingPathComponent("assets")
        let manager = AssetManager(accountId: account, accountKey: accountKey, store: store, directory: assetDirectory, api: api)
        let cancelled = Task {
            try await manager.cacheAsset(assetId: id) { received, total in
                if received == total { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled bytes were installed")
        } catch is CancellationError {}
        let afterCancellation = try await database.localAsset(id: id)
        XCTAssertNil(afterCancellation)
        let local = try await manager.cacheAsset(assetId: id)
        XCTAssertEqual(try Data(contentsOf: local.encryptedFileURL), encrypted)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let reopened = AssetManager(accountId: account, accountKey: accountKey, store: store, directory: assetDirectory)
        let restored = try await reopened.decryptedLocalData(assetId: id)
        XCTAssertEqual(restored, plaintext)
        let reused = try await reopened.cacheAsset(assetId: id)
        XCTAssertEqual(reused.id, id)
    }

    func testCorruptAssetIsNotInstalled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineCorrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 9, count: 32)
        let database = try SQLCipherDatabase(url: directory.appendingPathComponent("test.sqlite"), key: key)
        let store = EpistoriaStore(database: database)
        let id = try await store.save(payload: AssetPayload(mimeType: "text/plain", plaintextByteSize: 4,
            encryptedByteSize: 4, dedupeTag: "synthetic", assetKey: Base64URL.encode(key), originalFilename: "synthetic.txt"))
        MockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/download") == true {
                return try Self.jsonResponse(request, status: 200, object: [
                    "assetId": id.uuidString, "encryptedByteSize": "4",
                    "url": "https://objects.example.test/original", "expiresInSeconds": 60,
                ])
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(repeating: 0, count: 4))
        }
        let manager = AssetManager(accountId: UUID(), accountKey: key, store: store,
            directory: directory.appendingPathComponent("assets"), api: authenticatedAssetClient())
        do {
            _ = try await manager.cacheAsset(assetId: id)
            XCTFail("Unauthenticated bytes were installed")
        } catch let error as AssetManagerError { XCTAssertEqual(error, .assetIntegrityMismatch) }
        let local = try await database.localAsset(id: id)
        XCTAssertNil(local)
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

    private func authenticatedAssetClient() -> EpistoriaAPIClient {
        EpistoriaAPIClient(baseURL: URL(string: "https://sync.example.test")!,
            credentials: DeviceCredentials(ownerId: UUID(), deviceId: UUID(), token: "synthetic-token"),
            session: session())
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

private actor DownloadProgressRecorder {
    var values: [(Int64, Int64)] = []
    func record(_ received: Int64, _ total: Int64) { values.append((received, total)) }
}
