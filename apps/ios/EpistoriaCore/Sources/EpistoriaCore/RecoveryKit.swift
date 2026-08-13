import Foundation
import SwiftMnemonic

public enum RecoveryKitError: Error, Equatable {
    case invalidKey
    case invalidWords
}

public enum RecoveryKit {
    public static func words(for accountKey: Data) throws -> String {
        guard accountKey.count == 32 else {
            throw RecoveryKitError.invalidKey
        }
        do {
            return try Mnemonic(language: .english, entropy: accountKey).phrase.joined(separator: " ")
        } catch {
            throw RecoveryKitError.invalidKey
        }
    }

    public static func accountKey(from words: String) throws -> Data {
        let normalized = words
            .lowercased()
            .split(whereSeparator: \ .isWhitespace)
            .map(String.init)
        guard normalized.count == 24 else {
            throw RecoveryKitError.invalidWords
        }
        do {
            let mnemonic = try Mnemonic(from: normalized)
            guard mnemonic.entropy.count == 32 else {
                throw RecoveryKitError.invalidWords
            }
            return mnemonic.entropy
        } catch {
            throw RecoveryKitError.invalidWords
        }
    }
}

