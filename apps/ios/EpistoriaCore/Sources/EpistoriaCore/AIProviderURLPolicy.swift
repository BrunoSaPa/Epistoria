import Foundation
import Network

public enum AIProviderURLPolicy {
    public static func normalized(_ value: String, adapter: AIProviderAdapter) -> URL? {
        switch adapter {
        case .openAIResponses:
            return URL(string: "https://api.openai.com/v1")
        case .anthropicMessages:
            return URL(string: "https://api.anthropic.com/v1")
        case .geminiGenerateContent:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta")
        case .openAICompatible:
            break
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }
        if scheme == "http", !isLocal(host: host) { return nil }
        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + (components.path.isEmpty ? "v1" : components.path)
        return components.url
    }

    private static func isLocal(host: String) -> Bool {
        let host = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let address = IPv4Address(host) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 127
                || bytes[0] == 10
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
                || (bytes[0] == 169 && bytes[1] == 254)
        }
        if let address = IPv6Address(host) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let uniqueLocal = bytes[0] & 0xfe == 0xfc
            let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            return loopback || uniqueLocal || linkLocal
        }
        return false
    }
}
