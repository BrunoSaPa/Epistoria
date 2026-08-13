import Foundation

public enum Base64URL {
    public enum Error: Swift.Error, Equatable {
        case invalid
        case nonCanonical
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              })
        else {
            throw Error.invalid
        }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else {
            throw Error.invalid
        }
        guard encode(data) == value else {
            throw Error.nonCanonical
        }
        return data
    }
}

