import Foundation

public struct DeviceCredentials: Codable, Equatable, Sendable {
    public var ownerId: UUID
    public var deviceId: UUID
    public var token: String

    public init(ownerId: UUID, deviceId: UUID, token: String) {
        self.ownerId = ownerId
        self.deviceId = deviceId
        self.token = token
    }
}

public struct DeviceSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: String
    public var displayNameSealed: String?
    public var createdAt: String
    public var lastSeenAt: String
    public var revokedAt: String?
}

public struct SyncMutationWire: Codable, Equatable, Sendable {
    public var mutationId: UUID
    public var entityId: UUID
    public var entityType: EntityType
    public var operation: MutationOperation
    public var baseRevision: Int
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var clientModifiedAt: String
    public var envelope: EncryptedEnvelope
}

public struct MutationResultWire: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case accepted = "ACCEPTED"
        case conflict = "CONFLICT"
    }

    public var mutationId: UUID
    public var entityId: UUID
    public var status: Status
    public var revision: Int?
    public var sequence: String?
    public var conflictId: UUID?
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
    public var wireVersion: Int
    public var results: [MutationResultWire]
    public var serverSequence: String
}

public struct WireChange: Codable, Equatable, Sendable {
    public var sequence: String
    public var mutationId: UUID
    public var entityId: UUID
    public var entityType: EntityType
    public var operation: MutationOperation
    public var revision: Int
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var clientModifiedAt: String
    public var changedAt: String
    public var envelope: EncryptedEnvelope
}

public struct SyncPullResponse: Codable, Equatable, Sendable {
    public var wireVersion: Int
    public var changes: [WireChange]
    public var nextSequence: String
    public var latestSequence: String
    public var hasMore: Bool
}

public struct ServerConflictWire: Codable, Equatable, Sendable {
    public var id: UUID
    public var mutationId: UUID
    public var entityId: UUID
    public var entityType: EntityType
    public var operation: MutationOperation
    public var baseRevision: Int
    public var currentRevision: Int
    public var parentId: UUID?
    public var relationIds: [UUID]
    public var clientModifiedAt: String
    public var createdAt: String
    public var envelope: EncryptedEnvelope
}

public struct ServerConflictListResponse: Codable, Equatable, Sendable {
    public var conflicts: [ServerConflictWire]
}

public struct PreparedUpload: Codable, Equatable, Sendable {
    public var url: URL
    public var headers: [String: String]
    public var expiresInSeconds: Int
}

public struct AssetPrepareResponse: Codable, Equatable, Sendable {
    public var assetId: UUID
    public var deduplicated: Bool
    public var state: String
    public var upload: PreparedUpload?
}

public struct AssetConfirmResponse: Codable, Equatable, Sendable {
    public var assetId: UUID
    public var state: String
    public var availableAt: String
}

public struct AssetDownloadResponse: Codable, Equatable, Sendable {
    public var assetId: UUID
    public var encryptedByteSize: String
    public var url: URL
    public var expiresInSeconds: Int
}

public struct AIJobSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var jobType: String
    public var status: String
    public var attempts: Int
    public var artifactEntityId: UUID?
    public var errorCode: String?
    public var createdAt: String
    public var updatedAt: String
    public var completedAt: String?
}

public struct ConflictResolutionResponse: Codable, Equatable, Sendable {
    public var resolvedAt: String
}

public enum APIClientError: Error, Equatable {
    case invalidEndpoint
    case unauthorized
    case rejected(status: Int)
    case transport
    case invalidResponse
    case assetTooLarge
}

public struct APIRetryPolicy: Equatable, Sendable {
    public static let standard = APIRetryPolicy()

    public var maximumAttempts: Int
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var jitterRatio: Double

    public init(
        maximumAttempts: Int = 4,
        initialDelay: TimeInterval = 0.25,
        maximumDelay: TimeInterval = 4,
        jitterRatio: Double = 0.25
    ) {
        self.maximumAttempts = min(max(maximumAttempts, 1), 8)
        self.initialDelay = initialDelay.isFinite ? max(initialDelay, 0) : 0.25
        self.maximumDelay = maximumDelay.isFinite ? max(maximumDelay, 0) : 4
        self.jitterRatio = jitterRatio.isFinite ? min(max(jitterRatio, 0), 1) : 0.25
    }
}

public actor EpistoriaAPIClient {
    private struct SyncPushRequest: Encodable {
        var wireVersion = 1
        var deviceId: UUID
        var mutations: [SyncMutationWire]
    }

    private struct AssetPrepareRequest: Encodable {
        var assetId: UUID
        var dedupeTag: String
        var encryptedByteSize: Int64
    }

    private struct AssetConfirmRequest: Encodable {
        var encryptedByteSize: Int64
    }

    private struct BootstrapRequest: Encodable {
        var ownerId: UUID
        var deviceId: UUID
        var kind = "IPAD"
        var displayNameSealed: String?
    }

    private struct EnrollDeviceRequest: Encodable {
        var deviceId: UUID
        var kind: String
        var displayNameSealed: String?
    }

    private struct CreateJobRequest: Encodable {
        var jobId: UUID
        var jobType: String
        var cryptoVersion: Int
        var contentVersion: Int
        var sealedDek: String
        var sealedPayload: String
        var payloadSize: Int
    }

    private let baseURL: URL
    private let session: URLSession
    private let retryPolicy: APIRetryPolicy
    private let retrySleeper: @Sendable (TimeInterval) async throws -> Void
    private let jitterSource: @Sendable () -> Double
    private var credentials: DeviceCredentials?

    public init(
        baseURL: URL,
        credentials: DeviceCredentials? = nil,
        session: URLSession = .shared,
        retryPolicy: APIRetryPolicy = .standard,
        retrySleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        jitterSource: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) }
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
        self.retryPolicy = retryPolicy
        self.retrySleeper = retrySleeper
        self.jitterSource = jitterSource
    }

    public func setCredentials(_ credentials: DeviceCredentials) {
        self.credentials = credentials
    }

    public func bootstrap(
        ownerId: UUID,
        deviceId: UUID,
        bootstrapSecret: String,
        sealedDisplayName: String? = nil
    ) async throws -> DeviceCredentials {
        let response: DeviceCredentials = try await send(
            method: "POST",
            path: "auth/bootstrap",
            body: BootstrapRequest(
                ownerId: ownerId,
                deviceId: deviceId,
                displayNameSealed: sealedDisplayName
            ),
            authorization: false,
            additionalHeaders: ["x-bootstrap-secret": bootstrapSecret]
        )
        credentials = response
        return response
    }

    public func push(_ mutations: [SyncMutationWire]) async throws -> SyncPushResponse {
        guard let credentials else { throw APIClientError.unauthorized }
        return try await send(
            method: "POST",
            path: "sync/push",
            body: SyncPushRequest(deviceId: credentials.deviceId, mutations: mutations)
        )
    }

    public func enrollDevice(
        id: UUID,
        kind: String,
        sealedDisplayName: String? = nil
    ) async throws -> DeviceCredentials {
        try await send(
            method: "POST",
            path: "auth/devices",
            body: EnrollDeviceRequest(
                deviceId: id,
                kind: kind,
                displayNameSealed: sealedDisplayName
            )
        )
    }

    public func listDevices() async throws -> [DeviceSummary] {
        try await send(method: "GET", path: "auth/devices")
    }

    public func revokeDevice(id: UUID) async throws {
        try await sendWithoutResponse(
            method: "DELETE",
            path: "auth/devices/\(id.uuidString.lowercased())"
        )
    }

    public func pull(after sequence: String, limit: Int = 200) async throws -> SyncPullResponse {
        var components = URLComponents(
            url: try endpoint("sync/pull"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "after", value: sequence),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { throw APIClientError.invalidEndpoint }
        return try await send(method: "GET", url: url)
    }

    public func listUnresolvedConflicts() async throws -> ServerConflictListResponse {
        try await send(method: "GET", path: "sync/conflicts")
    }

    public func resolveConflict(
        id: UUID,
        replacementEntityId: UUID
    ) async throws -> ConflictResolutionResponse {
        struct Request: Encodable { var replacementEntityId: UUID }
        return try await send(
            method: "POST",
            path: "sync/conflicts/\(id.uuidString.lowercased())/resolve",
            body: Request(replacementEntityId: replacementEntityId)
        )
    }

    public func prepareAsset(_ asset: LocalAsset) async throws -> AssetPrepareResponse {
        try await send(
            method: "POST",
            path: "assets/prepare",
            body: AssetPrepareRequest(
                assetId: asset.id,
                dedupeTag: asset.dedupeTag,
                encryptedByteSize: asset.encryptedByteSize
            )
        )
    }

    public func uploadAsset(data: Data, prepared: PreparedUpload) async throws {
        var request = URLRequest(url: prepared.url)
        request.httpMethod = "PUT"
        for (name, value) in prepared.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let response = try await performUpload(request, data: data)
        guard (200 ... 299).contains(response.statusCode) else {
            throw APIClientError.rejected(status: response.statusCode)
        }
    }

    public func confirmAsset(id: UUID, byteSize: Int64) async throws -> AssetConfirmResponse {
        try await send(
            method: "POST",
            path: "assets/\(id.uuidString.lowercased())/confirm",
            body: AssetConfirmRequest(encryptedByteSize: byteSize)
        )
    }

    public func downloadAsset(id: UUID, maximumBytes: Int = 536_870_912) async throws -> Data {
        guard maximumBytes > 0 else { throw APIClientError.assetTooLarge }
        let descriptor: AssetDownloadResponse = try await send(
            method: "GET",
            path: "assets/\(id.uuidString.lowercased())/download"
        )
        guard descriptor.assetId == id,
              let declaredBytes = Int(descriptor.encryptedByteSize),
              declaredBytes > 0
        else { throw APIClientError.invalidResponse }
        guard declaredBytes <= maximumBytes else { throw APIClientError.assetTooLarge }

        var request = URLRequest(url: descriptor.url)
        request.httpMethod = "GET"
        let (data, response) = try await performData(request)
        guard (200 ... 299).contains(response.statusCode), data.count == declaredBytes else {
            throw APIClientError.invalidResponse
        }
        return data
    }

    public func createAIJob(
        id: UUID,
        type: String,
        envelope: EncryptedEnvelope
    ) async throws -> AIJobSummary {
        try await send(
            method: "POST",
            path: "ai-jobs",
            body: CreateJobRequest(
                jobId: id,
                jobType: type,
                cryptoVersion: envelope.cryptoVersion,
                contentVersion: envelope.contentVersion,
                sealedDek: envelope.sealedDek,
                sealedPayload: envelope.sealedContent,
                payloadSize: envelope.payloadSize
            )
        )
    }

    public func aiJob(id: UUID) async throws -> AIJobSummary {
        try await send(method: "GET", path: "ai-jobs/\(id.uuidString.lowercased())")
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: normalizedBaseURL())?.absoluteURL else {
            throw APIClientError.invalidEndpoint
        }
        return url
    }

    private func normalizedBaseURL() -> URL {
        if baseURL.absoluteString.hasSuffix("/") { return baseURL }
        return URL(string: baseURL.absoluteString + "/") ?? baseURL
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        authorization: Bool = true
    ) async throws -> Response {
        try await send(
            method: method,
            url: endpoint(path),
            bodyData: nil,
            authorization: authorization
        )
    }

    private func sendWithoutResponse(method: String, path: String) async throws {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        guard let credentials else { throw APIClientError.unauthorized }
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "authorization")
        let (_, http) = try await performData(request)
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIClientError.unauthorized
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw APIClientError.rejected(status: http.statusCode)
        }
    }

    private func send<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        body: Body,
        authorization: Bool = true,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try await send(
            method: method,
            url: endpoint(path),
            bodyData: try encoder.encode(body),
            authorization: authorization,
            additionalHeaders: additionalHeaders
        )
    }

    private func send<Response: Decodable>(
        method: String,
        url: URL
    ) async throws -> Response {
        try await send(method: method, url: url, bodyData: nil, authorization: true)
    }

    private func send<Response: Decodable>(
        method: String,
        url: URL,
        bodyData: Data?,
        authorization: Bool,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if authorization {
            guard let credentials else { throw APIClientError.unauthorized }
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "authorization")
        }
        let (data, http) = try await performData(request)
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIClientError.unauthorized
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw APIClientError.rejected(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIClientError.invalidResponse
        }
    }

    private func performData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0 ..< retryPolicy.maximumAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIClientError.invalidResponse
                }
                if shouldRetry(status: http.statusCode), attempt + 1 < retryPolicy.maximumAttempts {
                    try await waitBeforeRetry(attempt: attempt, response: http)
                    continue
                }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIClientError {
                throw error
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                guard shouldRetry(transportError: error) else {
                    throw APIClientError.transport
                }
                guard attempt + 1 < retryPolicy.maximumAttempts else {
                    throw APIClientError.transport
                }
                try await waitBeforeRetry(attempt: attempt, response: nil)
            }
        }
        throw APIClientError.transport
    }

    private func performUpload(_ request: URLRequest, data: Data) async throws -> HTTPURLResponse {
        for attempt in 0 ..< retryPolicy.maximumAttempts {
            do {
                let (_, response) = try await session.upload(for: request, from: data)
                guard let http = response as? HTTPURLResponse else {
                    throw APIClientError.invalidResponse
                }
                if shouldRetry(status: http.statusCode), attempt + 1 < retryPolicy.maximumAttempts {
                    try await waitBeforeRetry(attempt: attempt, response: http)
                    continue
                }
                return http
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIClientError {
                throw error
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                guard shouldRetry(transportError: error) else {
                    throw APIClientError.transport
                }
                guard attempt + 1 < retryPolicy.maximumAttempts else {
                    throw APIClientError.transport
                }
                try await waitBeforeRetry(attempt: attempt, response: nil)
            }
        }
        throw APIClientError.transport
    }

    private func shouldRetry(status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500 ... 599).contains(status)
    }

    private func shouldRetry(transportError error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func waitBeforeRetry(attempt: Int, response: HTTPURLResponse?) async throws {
        let exponential = min(
            retryPolicy.maximumDelay,
            retryPolicy.initialDelay * pow(2, Double(attempt))
        )
        let randomValue = jitterSource()
        let randomUnit = randomValue.isFinite ? min(max(randomValue, 0), 1) : 0.5
        let jitter = 1 + ((randomUnit * 2) - 1) * retryPolicy.jitterRatio
        let parsedRetryAfter = response
            .flatMap { $0.value(forHTTPHeaderField: "retry-after") }
            .flatMap(TimeInterval.init)
        let retryAfter = parsedRetryAfter?.isFinite == true ? max(parsedRetryAfter ?? 0, 0) : 0
        let delay = min(max(exponential * jitter, retryAfter), retryPolicy.maximumDelay)
        try await retrySleeper(delay)
    }
}
