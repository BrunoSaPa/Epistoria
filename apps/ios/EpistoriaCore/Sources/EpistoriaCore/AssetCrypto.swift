import Foundation
@preconcurrency import Sodium

public enum AssetCryptoError: Error, Equatable {
    case invalidKey
    case invalidFormat
    case unsupportedVersion
    case invalidChunk
    case authenticationFailed
    case missingFinalChunk
    case trailingData
}

public struct AssetCrypto: Sendable {
    public static let chunkBytes = 64 * 1024
    private static let magic = Data("EPISTORIA-ASSET".utf8) + Data([0])
    private let sodium = Sodium()

    public init() {}

    public func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw AssetCryptoError.invalidKey }
        let stream = sodium.secretStream.xchacha20poly1305
        guard let push = stream.initPush(secretKey: Array(key)) else {
            throw AssetCryptoError.invalidKey
        }
        var output = Self.magic + Data([1]) + Data(push.header())
        var offset = 0
        repeat {
            let end = min(offset + Self.chunkBytes, plaintext.count)
            let chunk = plaintext.subdata(in: offset ..< end)
            let final = end == plaintext.count
            guard let encrypted = push.push(
                message: Array(chunk),
                tag: final ? .FINAL : .MESSAGE
            ) else {
                throw AssetCryptoError.authenticationFailed
            }
            var length = UInt32(encrypted.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(contentsOf: encrypted)
            offset = end
        } while offset < plaintext.count
        return output
    }

    public func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw AssetCryptoError.invalidKey }
        let headerBytes = 24
        let prefixBytes = Self.magic.count + 1 + headerBytes
        guard encrypted.count >= prefixBytes + 4 + 17,
              encrypted.prefix(Self.magic.count) == Self.magic
        else {
            throw AssetCryptoError.invalidFormat
        }
        guard encrypted[Self.magic.count] == 1 else {
            throw AssetCryptoError.unsupportedVersion
        }
        let headerStart = Self.magic.count + 1
        let header = encrypted.subdata(in: headerStart ..< headerStart + headerBytes)
        guard let pull = sodium.secretStream.xchacha20poly1305.initPull(
            secretKey: Array(key),
            header: Array(header)
        ) else {
            throw AssetCryptoError.authenticationFailed
        }
        var cursor = prefixBytes
        var plaintext = Data()
        while cursor < encrypted.count {
            guard cursor + 4 <= encrypted.count else { throw AssetCryptoError.invalidChunk }
            let lengthData = encrypted.subdata(in: cursor ..< cursor + 4)
            let length = lengthData.withUnsafeBytes { pointer in
                UInt32(bigEndian: pointer.loadUnaligned(as: UInt32.self))
            }
            cursor += 4
            guard length >= 17,
                  length <= UInt32(Self.chunkBytes + 17),
                  cursor + Int(length) <= encrypted.count
            else {
                throw AssetCryptoError.invalidChunk
            }
            let cipher = encrypted.subdata(in: cursor ..< cursor + Int(length))
            cursor += Int(length)
            guard let (message, tag) = pull.pull(cipherText: Array(cipher)) else {
                throw AssetCryptoError.authenticationFailed
            }
            plaintext.append(contentsOf: message)
            switch tag {
            case .FINAL:
                guard cursor == encrypted.count else { throw AssetCryptoError.trailingData }
                return plaintext
            case .MESSAGE:
                continue
            default:
                throw AssetCryptoError.invalidChunk
            }
        }
        throw AssetCryptoError.missingFinalChunk
    }
}
