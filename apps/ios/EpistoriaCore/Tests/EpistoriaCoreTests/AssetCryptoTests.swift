import Foundation
import XCTest
@testable import EpistoriaCore

final class AssetCryptoTests: XCTestCase {
    func testRoundTripAtEveryChunkBoundary() throws {
        let crypto = AssetCrypto()
        let key = Data(0 ..< 32)
        for size in [0, 1, 65_536, 65_537, 131_072] {
            let plaintext = Data((0 ..< size).map { UInt8($0 % 251) })
            XCTAssertEqual(try crypto.decrypt(crypto.encrypt(plaintext, key: key), key: key), plaintext)
        }
    }

    func testTamperingTruncationAndTrailingDataFail() throws {
        let crypto = AssetCrypto()
        let key = Data(0 ..< 32)
        let encrypted = try crypto.encrypt(Data(repeating: 7, count: 70_000), key: key)
        var tampered = encrypted
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        XCTAssertThrowsError(try crypto.decrypt(tampered, key: key))
        XCTAssertThrowsError(try crypto.decrypt(encrypted.dropLast(), key: key))
        XCTAssertThrowsError(try crypto.decrypt(encrypted + Data([0]), key: key))
    }
}

