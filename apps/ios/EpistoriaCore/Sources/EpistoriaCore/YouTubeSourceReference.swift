import Foundation

public enum YouTubeReferenceError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedVideo
    case invalidStartTime

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Paste a secure YouTube video link without a username, password, or custom port."
        case .unsupportedVideo:
            "The link must point to one YouTube video, not a channel, playlist, or search page."
        case .invalidStartTime:
            "The YouTube start time is invalid or too large."
        }
    }
}

/// A normalized reference to one YouTube-hosted video. Epistoria stores the reference only. It
/// never downloads or caches YouTube audiovisual content through this type.
public struct YouTubeReference: Equatable, Sendable {
    public let videoID: String
    public let startSeconds: Int?
    public let canonicalURL: URL
    public let playbackURL: URL

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let rawHost = components.host?.lowercased()
        else { throw YouTubeReferenceError.invalidURL }

        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let query = components.queryItems ?? []
        let identifier: String

        switch host {
        case "youtu.be":
            guard path.count == 1, let first = path.first else {
                throw YouTubeReferenceError.unsupportedVideo
            }
            identifier = first
        case "youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com":
            if path == ["watch"] {
                let values = query.filter { $0.name == "v" }.compactMap(\.value)
                guard values.count == 1 else { throw YouTubeReferenceError.unsupportedVideo }
                identifier = values[0]
            } else if path.count == 2, ["shorts", "embed", "live"].contains(path[0]) {
                identifier = path[1]
            } else {
                throw YouTubeReferenceError.unsupportedVideo
            }
        default:
            throw YouTubeReferenceError.invalidURL
        }

        guard Self.isValidVideoID(identifier) else {
            throw YouTubeReferenceError.unsupportedVideo
        }
        let parsedStart = try Self.startSeconds(from: query)

        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "www.youtube.com"
        canonical.path = "/watch"
        canonical.queryItems = [URLQueryItem(name: "v", value: identifier)]
        guard let canonicalURL = canonical.url else { throw YouTubeReferenceError.invalidURL }

        var playback = canonical
        if let parsedStart {
            playback.queryItems?.append(URLQueryItem(name: "t", value: "\(parsedStart)s"))
        }
        guard let playbackURL = playback.url else { throw YouTubeReferenceError.invalidURL }

        self.videoID = identifier
        startSeconds = parsedStart
        self.canonicalURL = canonicalURL
        self.playbackURL = playbackURL
    }

    public var embedURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(videoID)"
        var query = [URLQueryItem(name: "playsinline", value: "1")]
        if let startSeconds {
            query.append(URLQueryItem(name: "start", value: String(startSeconds)))
        }
        components.queryItems = query
        return components.url!
    }

    private static func isValidVideoID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
    }

    private static func startSeconds(from items: [URLQueryItem]) throws -> Int? {
        let values = items.filter { $0.name == "t" || $0.name == "start" }.compactMap(\.value)
        guard !values.isEmpty else { return nil }
        guard values.count == 1, let value = values.first, !value.isEmpty else {
            throw YouTubeReferenceError.invalidStartTime
        }

        let total: Int
        if value.allSatisfy(\.isNumber) {
            guard let parsed = Int(value) else { throw YouTubeReferenceError.invalidStartTime }
            total = parsed
        } else {
            var remaining = value.lowercased()[...]
            var result = 0
            var found = false
            for (suffix, multiplier) in [("h", 3_600), ("m", 60), ("s", 1)] {
                guard let index = remaining.firstIndex(of: Character(suffix)) else { continue }
                let digits = remaining[..<index]
                guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let amount = Int(digits) else {
                    throw YouTubeReferenceError.invalidStartTime
                }
                result += amount * multiplier
                remaining = remaining[remaining.index(after: index)...]
                found = true
            }
            guard found, remaining.isEmpty else { throw YouTubeReferenceError.invalidStartTime }
            total = result
        }
        guard (0 ... 604_800).contains(total) else {
            throw YouTubeReferenceError.invalidStartTime
        }
        return total == 0 ? nil : total
    }
}
