import CryptoKit
import Foundation
@preconcurrency import Sodium

public struct EncryptedEnvelope: Codable, Equatable, Sendable {
    public var cryptoVersion: Int
    public var contentVersion: Int
    public var sealedDek: String
    public var sealedContent: String
    public var dedupeTag: String?
    public var payloadSize: Int

    public init(
        cryptoVersion: Int = 1,
        contentVersion: Int,
        sealedDek: String,
        sealedContent: String,
        dedupeTag: String? = nil,
        payloadSize: Int
    ) {
        self.cryptoVersion = cryptoVersion
        self.contentVersion = contentVersion
        self.sealedDek = sealedDek
        self.sealedContent = sealedContent
        self.dedupeTag = dedupeTag
        self.payloadSize = payloadSize
    }
}

public enum EntityCryptoError: Error, Equatable {
    case invalidKey
    case invalidMetadata
    case invalidEnvelope
    case unsupportedVersion
    case authenticationFailed
    case randomGenerationFailed
}

public struct EntityCrypto: Sendable {
    private static let accountKeyBytes = 32
    private static let sealedOverhead = 40
    private let sodium = Sodium()

    public init() {}

    public func entityAAD(
        accountId: UUID,
        entityType: EntityType,
        entityId: UUID,
        contentVersion: Int
    ) throws -> Data {
        guard (1 ... 65_535).contains(contentVersion) else {
            throw EntityCryptoError.invalidMetadata
        }
        return Data(
            "epistoria|entity|v1|\(canonical(accountId))|\(entityType.rawValue)|\(canonical(entityId))|\(contentVersion)"
                .utf8
        )
    }

    public func jobAAD(
        accountId: UUID,
        jobType: String,
        jobId: UUID,
        contentVersion: Int
    ) throws -> Data {
        guard (1 ... 65_535).contains(contentVersion),
              jobType.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil
        else {
            throw EntityCryptoError.invalidMetadata
        }
        return Data(
            "epistoria|job|v1|\(canonical(accountId))|\(jobType)|\(canonical(jobId))|\(contentVersion)"
                .utf8
        )
    }

    public func wrappingKey(accountKey: Data, accountId: UUID) throws -> Data {
        try derive(
            accountKey: accountKey,
            accountId: accountId,
            info: "epistoria/entity-wrap/v1"
        )
    }

    public func dedupeKey(accountKey: Data, accountId: UUID) throws -> Data {
        try derive(
            accountKey: accountKey,
            accountId: accountId,
            info: "epistoria/asset-dedupe/v1"
        )
    }

    public func localDatabaseKey(accountKey: Data, accountId: UUID) throws -> Data {
        try derive(
            accountKey: accountKey,
            accountId: accountId,
            info: "epistoria/local-database/v1"
        )
    }

    public func encryptEntity(
        _ plaintext: Data,
        accountKey: Data,
        accountId: UUID,
        entityType: EntityType,
        entityId: UUID,
        contentVersion: Int = 1
    ) throws -> EncryptedEnvelope {
        let aad = try entityAAD(
            accountId: accountId,
            entityType: entityType,
            entityId: entityId,
            contentVersion: contentVersion
        )
        return try encryptPayload(
            plaintext,
            accountKey: accountKey,
            accountId: accountId,
            aad: aad,
            contentVersion: contentVersion
        )
    }

    public func encryptJob(
        _ plaintext: Data,
        accountKey: Data,
        accountId: UUID,
        jobType: String,
        jobId: UUID,
        contentVersion: Int = 1
    ) throws -> EncryptedEnvelope {
        let aad = try jobAAD(
            accountId: accountId,
            jobType: jobType,
            jobId: jobId,
            contentVersion: contentVersion
        )
        return try encryptPayload(
            plaintext,
            accountKey: accountKey,
            accountId: accountId,
            aad: aad,
            contentVersion: contentVersion
        )
    }

    public func decryptEntity(
        _ envelope: EncryptedEnvelope,
        accountKey: Data,
        accountId: UUID,
        entityType: EntityType,
        entityId: UUID
    ) throws -> Data {
        let aad = try entityAAD(
            accountId: accountId,
            entityType: entityType,
            entityId: entityId,
            contentVersion: envelope.contentVersion
        )
        return try decryptPayload(
            envelope,
            accountKey: accountKey,
            accountId: accountId,
            aad: aad
        )
    }

    public func dedupeTag(
        plaintext: Data,
        accountKey: Data,
        accountId: UUID
    ) throws -> String {
        let key = try dedupeKey(accountKey: accountKey, accountId: accountId)
        let digest = Data(SHA256.hash(data: plaintext))
        let authentication = HMAC<SHA256>.authenticationCode(
            for: digest,
            using: SymmetricKey(data: key)
        )
        return Data(authentication).map { String(format: "%02x", $0) }.joined()
    }

    public func randomKey() throws -> Data {
        guard let bytes = sodium.randomBytes.buf(length: Self.accountKeyBytes) else {
            throw EntityCryptoError.randomGenerationFailed
        }
        return Data(bytes)
    }

    private func encryptPayload(
        _ plaintext: Data,
        accountKey: Data,
        accountId: UUID,
        aad: Data,
        contentVersion: Int
    ) throws -> EncryptedEnvelope {
        let dek = try randomKey()
        let wrap = try wrappingKey(accountKey: accountKey, accountId: accountId)
        let sealedDekResult: Bytes? = sodium.aead.xchacha20poly1305ietf.encrypt(
            message: Array(dek),
            secretKey: Array(wrap),
            additionalData: Array(aad + Data("|dek".utf8))
        )
        let sealedContentResult: Bytes? = sodium.aead.xchacha20poly1305ietf.encrypt(
            message: Array(plaintext),
            secretKey: Array(dek),
            additionalData: Array(aad)
        )
        guard let sealedDek = sealedDekResult, let sealedContent = sealedContentResult else {
            throw EntityCryptoError.authenticationFailed
        }
        return EncryptedEnvelope(
            contentVersion: contentVersion,
            sealedDek: Base64URL.encode(Data(sealedDek)),
            sealedContent: Base64URL.encode(Data(sealedContent)),
            payloadSize: plaintext.count
        )
    }

    private func decryptPayload(
        _ envelope: EncryptedEnvelope,
        accountKey: Data,
        accountId: UUID,
        aad: Data
    ) throws -> Data {
        guard envelope.cryptoVersion == 1 else {
            throw EntityCryptoError.unsupportedVersion
        }
        let sealedDek: Data
        let sealedContent: Data
        do {
            sealedDek = try Base64URL.decode(envelope.sealedDek)
            sealedContent = try Base64URL.decode(envelope.sealedContent)
        } catch {
            throw EntityCryptoError.invalidEnvelope
        }
        guard sealedDek.count == 32 + Self.sealedOverhead,
              sealedContent.count == envelope.payloadSize + Self.sealedOverhead,
              envelope.payloadSize >= 0
        else {
            throw EntityCryptoError.invalidEnvelope
        }
        let wrap = try wrappingKey(accountKey: accountKey, accountId: accountId)
        guard let dek = sodium.aead.xchacha20poly1305ietf.decrypt(
            nonceAndAuthenticatedCipherText: Array(sealedDek),
            secretKey: Array(wrap),
            additionalData: Array(aad + Data("|dek".utf8))
        ), dek.count == 32,
        let plaintext = sodium.aead.xchacha20poly1305ietf.decrypt(
            nonceAndAuthenticatedCipherText: Array(sealedContent),
            secretKey: dek,
            additionalData: Array(aad)
        ), plaintext.count == envelope.payloadSize
        else {
            throw EntityCryptoError.authenticationFailed
        }
        return Data(plaintext)
    }

    private func derive(accountKey: Data, accountId: UUID, info: String) throws -> Data {
        guard accountKey.count == Self.accountKeyBytes else {
            throw EntityCryptoError.invalidKey
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: accountKey),
            salt: uuidData(accountId),
            info: Data(info.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private func uuidData(_ value: UUID) -> Data {
        var bytes = value.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    private func canonical(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }
}
