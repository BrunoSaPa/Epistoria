import Foundation
import XCTest
@testable import EpistoriaCore

private final class TrustMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class CoreTrustTests: XCTestCase {
    override func tearDown() {
        TrustMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testRetryableResponsesUseABoundedPolicyAndEventuallySucceed() async throws {
        let attempts = LockedCounter()
        let ownerId = UUID()
        let deviceId = UUID()
        let token = String(repeating: "r", count: 43)
        TrustMockURLProtocol.handler = { request in
            let attempt = attempts.increment()
            if attempt < 3 {
                return try Self.response(
                    request,
                    status: 503,
                    object: ["error": "temporarily unavailable"],
                    headers: ["retry-after": "0"]
                )
            }
            return try Self.response(request, status: 201, object: [
                "ownerId": ownerId.uuidString.lowercased(),
                "deviceId": deviceId.uuidString.lowercased(),
                "token": token,
            ])
        }
        let client = retryingClient()

        let credentials = try await client.bootstrap(
            ownerId: ownerId,
            deviceId: deviceId,
            bootstrapSecret: String(repeating: "b", count: 32)
        )

        XCTAssertEqual(credentials.token, token)
        XCTAssertEqual(attempts.value, 3)
    }

    func testTransportTimeoutsRetryButPermanentTransportErrorsDoNot() async throws {
        let attempts = LockedCounter()
        let ownerId = UUID()
        let deviceId = UUID()
        let token = String(repeating: "n", count: 43)
        TrustMockURLProtocol.handler = { request in
            if attempts.increment() < 3 { throw URLError(.timedOut) }
            return try Self.response(request, status: 201, object: [
                "ownerId": ownerId.uuidString.lowercased(),
                "deviceId": deviceId.uuidString.lowercased(),
                "token": token,
            ])
        }
        let client = retryingClient()
        _ = try await client.bootstrap(
            ownerId: ownerId,
            deviceId: deviceId,
            bootstrapSecret: String(repeating: "b", count: 32)
        )
        XCTAssertEqual(attempts.value, 3)

        let permanentAttempts = LockedCounter()
        TrustMockURLProtocol.handler = { _ in
            _ = permanentAttempts.increment()
            throw URLError(.badURL)
        }
        do {
            _ = try await client.listDevices()
            XCTFail("Expected a permanent transport error")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .transport)
        }
        XCTAssertEqual(permanentAttempts.value, 1)
    }

    func testRetryableResponsesStopAtTheConfiguredAttemptLimit() async throws {
        let attempts = LockedCounter()
        TrustMockURLProtocol.handler = { request in
            _ = attempts.increment()
            return try Self.response(
                request,
                status: 429,
                object: ["error": "throttled"],
                headers: ["retry-after": "0"]
            )
        }
        let client = retryingClient()

        do {
            _ = try await client.bootstrap(
                ownerId: UUID(),
                deviceId: UUID(),
                bootstrapSecret: String(repeating: "b", count: 32)
            )
            XCTFail("Expected the bounded retry policy to surface the final response")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .rejected(status: 429))
        }
        XCTAssertEqual(attempts.value, 3)
    }

    func testDeviceListingAndRevocationUseAuthenticatedEndpoints() async throws {
        let ownerId = UUID()
        let currentDeviceId = UUID()
        let otherDeviceId = UUID()
        let token = String(repeating: "d", count: 43)
        let deletes = LockedCounter()
        TrustMockURLProtocol.handler = { request in
            guard request.value(forHTTPHeaderField: "authorization") == "Bearer \(token)" else {
                return try Self.response(request, status: 401, object: ["error": "auth"])
            }
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/auth/devices"):
                return Self.dataResponse(
                    request,
                    status: 200,
                    data: try JSONSerialization.data(withJSONObject: [[
                        "id": otherDeviceId.uuidString.lowercased(),
                        "kind": "MAC",
                        "displayNameSealed": NSNull(),
                        "createdAt": "2026-08-11T12:00:00.000Z",
                        "lastSeenAt": "2026-08-11T12:30:00.000Z",
                        "revokedAt": NSNull(),
                    ]])
                )
            case ("DELETE", "/v1/auth/devices/\(otherDeviceId.uuidString.lowercased())"):
                _ = deletes.increment()
                return Self.dataResponse(request, status: 204, data: Data())
            default:
                return try Self.response(request, status: 404, object: ["error": "wrong path"])
            }
        }
        let client = EpistoriaAPIClient(
            baseURL: URL(string: "https://sync.example.test/v1/")!,
            credentials: DeviceCredentials(
                ownerId: ownerId,
                deviceId: currentDeviceId,
                token: token
            ),
            session: session()
        )

        let devices = try await client.listDevices()
        try await client.revokeDevice(id: otherDeviceId)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, otherDeviceId)
        XCTAssertEqual(devices.first?.kind, "MAC")
        XCTAssertNil(devices.first?.revokedAt)
        XCTAssertEqual(deletes.value, 1)
    }

    func testSynchronizeHydratesAndDecryptsServerConflictsIdempotently() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountId = UUID()
        let deviceId = UUID()
        let entityId = UUID()
        let accountKey = Data(0 ..< 32)
        let syncedContent = try CanonicalJSON.encode(NotePayload(title: "Synced version"))
        let candidateContent = try CanonicalJSON.encode(NotePayload(title: "Preserved version"))
        let crypto = EntityCrypto()
        let syncedEnvelope = try crypto.encryptEntity(
            syncedContent,
            accountKey: accountKey,
            accountId: accountId,
            entityType: .note,
            entityId: entityId
        )
        let candidateEnvelope = try crypto.encryptEntity(
            candidateContent,
            accountKey: accountKey,
            accountId: accountId,
            entityType: .note,
            entityId: entityId
        )
        let timestamp = "2026-08-11T12:00:00.000Z"
        let conflictId = UUID()
        let pullChange = WireChange(
            sequence: "1",
            mutationId: UUID(),
            entityId: entityId,
            entityType: .note,
            operation: .upsert,
            revision: 1,
            parentId: nil,
            relationIds: [],
            clientModifiedAt: timestamp,
            changedAt: timestamp,
            envelope: syncedEnvelope
        )
        let serverConflict = ServerConflictWire(
            id: conflictId,
            mutationId: UUID(),
            entityId: entityId,
            entityType: .note,
            operation: .upsert,
            baseRevision: 0,
            currentRevision: 1,
            parentId: nil,
            relationIds: [],
            clientModifiedAt: timestamp,
            createdAt: timestamp,
            envelope: candidateEnvelope
        )
        TrustMockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sync/pull":
                let afterOne = request.url?.query?.contains("after=1") == true
                return try Self.encodedResponse(
                    request,
                    value: SyncPullResponse(
                        wireVersion: 1,
                        changes: afterOne ? [] : [pullChange],
                        nextSequence: "1",
                        latestSequence: "1",
                        hasMore: false
                    )
                )
            case "/v1/sync/conflicts":
                return try Self.encodedResponse(
                    request,
                    value: ServerConflictListResponse(conflicts: [serverConflict])
                )
            default:
                return try Self.response(request, status: 404, object: ["error": "wrong path"])
            }
        }
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("sync.sqlite"),
            key: Data(repeating: 11, count: 32)
        )
        let api = EpistoriaAPIClient(
            baseURL: URL(string: "https://sync.example.test/v1/")!,
            credentials: DeviceCredentials(
                ownerId: accountId,
                deviceId: deviceId,
                token: String(repeating: "t", count: 43)
            ),
            session: session()
        )
        let engine = SyncEngine(
            accountId: accountId,
            accountKey: accountKey,
            database: database,
            api: api
        )

        let first = try await engine.synchronize()
        let second = try await engine.synchronize()
        let conflicts = try await database.conflicts()
        let entity = try await database.entity(id: entityId)

        XCTAssertEqual(first.pulledChanges, 1)
        XCTAssertEqual(first.conflictsHydrated, 1)
        XCTAssertEqual(second.conflictsHydrated, 0)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.serverConflictId, conflictId)
        XCTAssertEqual(conflicts.first?.candidateContent, candidateContent)
        XCTAssertEqual(entity?.content, syncedContent)
        XCTAssertEqual(entity?.syncState, .conflict)
    }

    func testMissingRestoredAssetDownloadsAuthenticatesAndCachesAtomically() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountId = UUID()
        let assetId = UUID()
        let accountKey = Data(0 ..< 32)
        let assetKey = Data(repeating: 42, count: 32)
        let plaintext = Data("%PDF-1.4\nRestored private bytes\n%%EOF".utf8)
        let encrypted = try AssetCrypto().encrypt(plaintext, key: assetKey)
        let dedupeTag = try EntityCrypto().dedupeTag(
            plaintext: plaintext,
            accountKey: accountKey,
            accountId: accountId
        )
        let metadata = AssetPayload(
            mimeType: "application/pdf",
            plaintextByteSize: Int64(plaintext.count),
            encryptedByteSize: Int64(encrypted.count),
            dedupeTag: dedupeTag,
            assetKey: Base64URL.encode(assetKey),
            originalFilename: "restored.pdf"
        )
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("restore.sqlite"),
            key: Data(repeating: 12, count: 32)
        )
        try await database.applyRemote(
            StoredEntity(
                id: assetId,
                entityType: .asset,
                parentId: nil,
                relationIds: [],
                content: try CanonicalJSON.encode(metadata),
                revision: 1,
                tombstone: false,
                clientModifiedAt: metadata.updatedAt,
                syncState: .synced
            ),
            search: nil
        )
        let objectDownloads = LockedCounter()
        TrustMockURLProtocol.handler = { request in
            if request.url?.host == "objects.example.test" {
                _ = objectDownloads.increment()
                return Self.dataResponse(request, status: 200, data: encrypted)
            }
            return try Self.response(request, status: 200, object: [
                "assetId": assetId.uuidString.lowercased(),
                "encryptedByteSize": String(encrypted.count),
                "url": "https://objects.example.test/restored.epistoria",
                "expiresInSeconds": 60,
            ])
        }
        let api = EpistoriaAPIClient(
            baseURL: URL(string: "https://sync.example.test/v1/")!,
            credentials: DeviceCredentials(
                ownerId: accountId,
                deviceId: UUID(),
                token: String(repeating: "a", count: 43)
            ),
            session: session()
        )
        let cacheDirectory = directory.appendingPathComponent("Assets", isDirectory: true)
        let manager = AssetManager(
            accountId: accountId,
            accountKey: accountKey,
            store: EpistoriaStore(database: database),
            directory: cacheDirectory,
            api: api
        )

        do {
            _ = try await manager.decryptedLocalData(assetId: assetId)
            XCTFail("Expected the local-only read to avoid restoration")
        } catch let error as AssetManagerError {
            XCTAssertEqual(error, .encryptedAssetUnavailable)
        }
        XCTAssertEqual(objectDownloads.value, 0)
        let first = try await manager.decryptedData(assetId: assetId)
        let second = try await manager.decryptedLocalData(assetId: assetId)
        let local = try await database.localAsset(id: assetId)

        XCTAssertEqual(first, plaintext)
        XCTAssertEqual(second, plaintext)
        XCTAssertEqual(objectDownloads.value, 1)
        XCTAssertEqual(local?.uploadState, .available)
        XCTAssertEqual(local?.encryptedByteSize, Int64(encrypted.count))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(local?.encryptedFileURL)), encrypted)
    }

    func testTamperedRestoredAssetIsNeverRegisteredOrCached() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountId = UUID()
        let assetId = UUID()
        let accountKey = Data(0 ..< 32)
        let assetKey = Data(repeating: 9, count: 32)
        let plaintext = Data("%PDF-1.4\nAuthenticated content\n%%EOF".utf8)
        let encrypted = try AssetCrypto().encrypt(plaintext, key: assetKey)
        var tampered = encrypted
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        let metadata = AssetPayload(
            mimeType: "application/pdf",
            plaintextByteSize: Int64(plaintext.count),
            encryptedByteSize: Int64(encrypted.count),
            dedupeTag: try EntityCrypto().dedupeTag(
                plaintext: plaintext,
                accountKey: accountKey,
                accountId: accountId
            ),
            assetKey: Base64URL.encode(assetKey),
            originalFilename: "tampered.pdf"
        )
        let database = try SQLCipherDatabase(
            url: directory.appendingPathComponent("tampered.sqlite"),
            key: Data(repeating: 13, count: 32)
        )
        try await database.applyRemote(
            StoredEntity(
                id: assetId,
                entityType: .asset,
                parentId: nil,
                relationIds: [],
                content: try CanonicalJSON.encode(metadata),
                revision: 1,
                tombstone: false,
                clientModifiedAt: metadata.updatedAt,
                syncState: .synced
            ),
            search: nil
        )
        TrustMockURLProtocol.handler = { request in
            if request.url?.host == "objects.example.test" {
                return Self.dataResponse(request, status: 200, data: tampered)
            }
            return try Self.response(request, status: 200, object: [
                "assetId": assetId.uuidString.lowercased(),
                "encryptedByteSize": String(tampered.count),
                "url": "https://objects.example.test/tampered.epistoria",
                "expiresInSeconds": 60,
            ])
        }
        let api = EpistoriaAPIClient(
            baseURL: URL(string: "https://sync.example.test/v1/")!,
            credentials: DeviceCredentials(
                ownerId: accountId,
                deviceId: UUID(),
                token: String(repeating: "a", count: 43)
            ),
            session: session()
        )
        let cacheDirectory = directory.appendingPathComponent("Assets", isDirectory: true)
        let manager = AssetManager(
            accountId: accountId,
            accountKey: accountKey,
            store: EpistoriaStore(database: database),
            directory: cacheDirectory,
            api: api
        )

        do {
            _ = try await manager.decryptedData(assetId: assetId)
            XCTFail("Expected authentication failure")
        } catch let error as AssetManagerError {
            XCTAssertEqual(error, .assetIntegrityMismatch)
        }
        let rejectedLocalAsset = try await database.localAsset(id: assetId)
        XCTAssertNil(rejectedLocalAsset)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cacheDirectory
                    .appendingPathComponent("\(assetId.uuidString.lowercased()).epistoria")
                    .path
            )
        )
    }

    private func retryingClient() -> EpistoriaAPIClient {
        EpistoriaAPIClient(
            baseURL: URL(string: "https://sync.example.test/v1/")!,
            session: session(),
            retryPolicy: APIRetryPolicy(
                maximumAttempts: 3,
                initialDelay: 0,
                maximumDelay: 0,
                jitterRatio: 0
            ),
            retrySleeper: { _ in },
            jitterSource: { 0.5 }
        )
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrustMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpistoriaTrustTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        object: [String: Any],
        headers: [String: String] = [:]
    ) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"].merging(headers) { _, new in new }
            )!,
            try JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func encodedResponse<Value: Encodable>(
        _ request: URLRequest,
        value: Value
    ) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"]
            )!,
            try JSONEncoder().encode(value)
        )
    }

    private static func dataResponse(
        _ request: URLRequest,
        status: Int,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["content-type": "application/octet-stream"]
            )!,
            data
        )
    }
}
