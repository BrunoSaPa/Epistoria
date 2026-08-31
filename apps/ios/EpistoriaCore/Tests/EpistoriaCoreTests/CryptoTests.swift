import Foundation
import XCTest
@testable import EpistoriaCore

final class CryptoTests: XCTestCase {
    private struct Fixture: Decodable {
        var accountId: UUID
        var accountKey: String
        var entityId: UUID
        var entityType: String
        var contentVersion: Int
        var wrappingKey: String
        var dedupeKey: String
        var plaintext: String
        var recoveryWords: String
        var sealedDek: String
        var sealedContent: String
        var payloadSize: Int
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "crypto-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testPythonGoldenVectorDecryptsInSwift() throws {
        let fixture = try fixture()
        let accountKey = try Base64URL.decode(fixture.accountKey)
        let crypto = EntityCrypto()
        XCTAssertEqual(
            Base64URL.encode(
                try crypto.wrappingKey(accountKey: accountKey, accountId: fixture.accountId)
            ),
            fixture.wrappingKey
        )
        XCTAssertEqual(
            Base64URL.encode(
                try crypto.dedupeKey(accountKey: accountKey, accountId: fixture.accountId)
            ),
            fixture.dedupeKey
        )
        let envelope = EncryptedEnvelope(
            contentVersion: fixture.contentVersion,
            sealedDek: fixture.sealedDek,
            sealedContent: fixture.sealedContent,
            payloadSize: fixture.payloadSize
        )
        let plaintext = try crypto.decryptEntity(
            envelope,
            accountKey: accountKey,
            accountId: fixture.accountId,
            entityType: .note,
            entityId: fixture.entityId
        )
        XCTAssertEqual(Base64URL.encode(plaintext), fixture.plaintext)
        XCTAssertEqual(try RecoveryKit.words(for: accountKey), fixture.recoveryWords)
        XCTAssertEqual(try RecoveryKit.accountKey(from: fixture.recoveryWords), accountKey)
    }

    func testEnvelopeRoundTripAndAuthenticatedMetadata() throws {
        let crypto = EntityCrypto()
        let key = try crypto.randomKey()
        let accountId = UUID()
        let entityId = UUID()
        let plaintext = Data("local-only synthetic note".utf8)
        let envelope = try crypto.encryptEntity(
            plaintext,
            accountKey: key,
            accountId: accountId,
            entityType: .note,
            entityId: entityId
        )
        XCTAssertEqual(
            try crypto.decryptEntity(
                envelope,
                accountKey: key,
                accountId: accountId,
                entityType: .note,
                entityId: entityId
            ),
            plaintext
        )
        XCTAssertThrowsError(
            try crypto.decryptEntity(
                envelope,
                accountKey: key,
                accountId: accountId,
                entityType: .source,
                entityId: entityId
            )
        )
        var tampered = try Base64URL.decode(envelope.sealedContent)
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        var changed = envelope
        changed.sealedContent = Base64URL.encode(tampered)
        XCTAssertThrowsError(
            try crypto.decryptEntity(
                changed,
                accountKey: key,
                accountId: accountId,
                entityType: .note,
                entityId: entityId
            )
        )
    }

    func testBase64URLRejectsPaddingAndNonURLAlphabet() throws {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff, 0x00])), "-_8A")
        XCTAssertEqual(try Base64URL.decode("-_8A"), Data([0xfb, 0xff, 0x00]))
        XCTAssertThrowsError(try Base64URL.decode("-_8A="))
        XCTAssertThrowsError(try Base64URL.decode("+/8A"))
    }
}

