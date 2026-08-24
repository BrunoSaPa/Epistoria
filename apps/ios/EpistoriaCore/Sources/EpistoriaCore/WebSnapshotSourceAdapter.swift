import Foundation

public struct WebSnapshot: Equatable, Sendable {
    public var requestedURL: URL
    public var capturedURL: URL
    public var mimeType: String
    public var title: String
    public var data: Data
    public var readableText: String

    public init(
        requestedURL: URL,
        capturedURL: URL,
        mimeType: String,
        title: String,
        data: Data,
        readableText: String
    ) {
        self.requestedURL = requestedURL
        self.capturedURL = capturedURL
        self.mimeType = mimeType
        self.title = title
        self.data = data
        self.readableText = readableText
    }
}

public struct WebSnapshotDifference: Equatable, Sendable {
    public var previousVersionAvailable: Bool
    public var addedParagraphCount: Int
    public var removedParagraphCount: Int
    public var addedExamples: [String]
    public var removedExamples: [String]

    public init(previousText: String?, currentText: String) {
        previousVersionAvailable = previousText != nil
        let previous = Self.paragraphs(in: previousText ?? "")
        let current = Self.paragraphs(in: currentText)
        let added = Self.subtract(current, removing: previous)
        let removed = Self.subtract(previous, removing: current)
        addedParagraphCount = added.count
        removedParagraphCount = removed.count
        addedExamples = added.prefix(3).map(Self.preview)
        removedExamples = removed.prefix(3).map(Self.preview)
    }

    public var isUnchanged: Bool {
        previousVersionAvailable && addedParagraphCount == 0 && removedParagraphCount == 0
    }

    private static func paragraphs(in text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func preview(_ paragraph: String) -> String {
        guard paragraph.count > 180 else { return paragraph }
        return String(paragraph.prefix(177)) + "…"
    }

    private static func subtract(_ values: [String], removing removals: [String]) -> [String] {
        var counts = removals.reduce(into: [String: Int]()) { result, value in
            result[value, default: 0] += 1
        }
        return values.filter { value in
            guard let count = counts[value], count > 0 else { return true }
            counts[value] = count - 1
            return false
        }
    }
}

public enum WebSnapshotCaptureError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedContentType
    case httpStatus(Int)
    case tooLarge
    case networkUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a complete HTTPS webpage address without embedded credentials."
        case .unsupportedContentType:
            "The address did not return an HTML webpage. No Source was created."
        case let .httpStatus(status):
            "The webpage returned HTTP status \(status). No Source was created."
        case .tooLarge:
            "The webpage snapshot is too large to capture safely."
        case .networkUnavailable:
            "The webpage could not be reached. Check the connection and try again."
        }
    }
}

public protocol WebSnapshotCapturing: Sendable {
    func capture(url: URL) async throws -> WebSnapshot
}

public struct WebSnapshotCaptureService: WebSnapshotCapturing, Sendable {
    public static let maximumBytes = 16 * 1_024 * 1_024

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func capture(url: URL) async throws -> WebSnapshot {
        let requestedURL = try Self.validatedURL(url)
        var request = URLRequest(url: requestedURL)
        request.httpMethod = "GET"
        request.setValue(
            "text/html, application/xhtml+xml;q=0.9",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("Epistoria/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebSnapshotCaptureError.unsupportedContentType
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw WebSnapshotCaptureError.httpStatus(http.statusCode)
            }
            let capturedURL = try Self.validatedURL(http.url ?? requestedURL)
            let mimeType = (http.mimeType ?? "").lowercased()
            guard mimeType == "text/html" || mimeType == "application/xhtml+xml" else {
                throw WebSnapshotCaptureError.unsupportedContentType
            }
            if http.expectedContentLength > Int64(Self.maximumBytes) {
                throw WebSnapshotCaptureError.tooLarge
            }

            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), Self.maximumBytes))
            }
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else {
                    throw WebSnapshotCaptureError.tooLarge
                }
                data.append(byte)
            }

            let adapter = WebSnapshotSourceAdapter()
            try adapter.validate(data: data, filename: "snapshot.epistoriaweb", mimeType: mimeType)
            let readableText = try adapter.extractText(data: data) ?? ""
            let rawTitle = try adapter.documentTitle(data: data)
                ?? capturedURL.host
                ?? "Webpage"
            let title = String(
                rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)
            )
            return WebSnapshot(
                requestedURL: requestedURL,
                capturedURL: capturedURL,
                mimeType: mimeType,
                title: title.isEmpty ? "Webpage" : title,
                data: data,
                readableText: readableText
            )
        } catch let error as WebSnapshotCaptureError {
            throw error
        } catch let error as SourceAdapterError {
            if error == .tooLarge { throw WebSnapshotCaptureError.tooLarge }
            throw error
        } catch {
            throw WebSnapshotCaptureError.networkUnavailable
        }
    }

    public static func validatedURL(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else { throw WebSnapshotCaptureError.invalidURL }
        var normalized = components
        normalized.scheme = scheme
        normalized.fragment = nil
        guard let result = normalized.url else { throw WebSnapshotCaptureError.invalidURL }
        return result
    }
}

public struct HTMLSourceAdapter: SourceAdapter {
    public let sourceType = ResourceKind.html
    public let supportedExtensions: Set<String> = ["htm", "html"]
    public let maximumBytes = 32 * 1_024 * 1_024

    public init() {}

    public func validate(data: Data, filename _: String, mimeType _: String) throws {
        _ = try HTMLSnapshotDocument(data: data, maximumBytes: maximumBytes)
    }

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .html, mimeType: mimeType)
    }

    public func extractText(data: Data) throws -> String? {
        try HTMLSnapshotDocument(data: data, maximumBytes: maximumBytes).readableText
    }

    public func thumbnail(data _: Data) throws -> Data? { nil }

    public func readableExport(data: Data) throws -> Data {
        Data(try HTMLSnapshotDocument(data: data, maximumBytes: maximumBytes).readableText.utf8)
    }
}

public struct WebSnapshotSourceAdapter: SourceAdapter {
    public let sourceType = ResourceKind.website
    public let supportedExtensions: Set<String> = ["epistoriaweb"]
    public let maximumBytes = WebSnapshotCaptureService.maximumBytes

    public init() {}

    public func validate(data: Data, filename _: String, mimeType: String) throws {
        let normalizedMIME = mimeType.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init)
        guard normalizedMIME == "text/html" || normalizedMIME == "application/xhtml+xml" else {
            throw SourceAdapterError.unsupportedType
        }
        _ = try HTMLSnapshotDocument(data: data, maximumBytes: maximumBytes)
    }

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .website, mimeType: mimeType)
    }

    public func extractText(data: Data) throws -> String? {
        try HTMLSnapshotDocument(data: data, maximumBytes: maximumBytes).readableText
    }

    public func documentTitle(data: Data) throws -> String? {
        try HTMLSnapshotDocument(data: data, maximumBytes: maximumBytes).title
    }

    public func thumbnail(data _: Data) throws -> Data? { nil }

    public func readableExport(data: Data) throws -> Data {
        Data(try HTMLSnapshotDocument(data: data, maximumBytes: maximumBytes).readableText.utf8)
    }
}

private struct HTMLSnapshotDocument {
    var title: String?
    var readableText: String

    init(data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw SourceAdapterError.tooLarge }
        guard !data.isEmpty else { throw SourceAdapterError.containsNoReadableText }
        let source: String
        if let utf8 = String(data: data, encoding: .utf8) {
            source = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            source = latin1
        } else {
            throw SourceAdapterError.malformed
        }
        guard !source.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SourceAdapterError.malformed
        }

        title = Self.firstCapture(
            pattern: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#,
            in: source
        ).map(Self.cleanFragment)
        let withoutInactive = Self.replacing(
            pattern: #"(?is)<(head|script|style|noscript|template)\b[^>]*>.*?</\1\s*>"#,
            in: source,
            with: "\n"
        )
        let withoutComments = Self.replacing(
            pattern: #"(?s)<!--.*?-->"#,
            in: withoutInactive,
            with: " "
        )
        let withBreaks = Self.replacing(
            pattern: #"(?i)</?(address|article|aside|blockquote|br|dd|div|dl|dt|figcaption|figure|footer|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|table|tbody|td|tfoot|th|thead|tr|ul)\b[^>]*>"#,
            in: withoutComments,
            with: "\n"
        )
        let withoutTags = Self.replacing(pattern: #"(?s)<[^>]*>"#, in: withBreaks, with: " ")
        readableText = Self.cleanFragment(withoutTags)
        guard !readableText.isEmpty else { throw SourceAdapterError.containsNoReadableText }
        if title?.isEmpty == true { title = nil }
    }

    private static func firstCapture(pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }

    private static func cleanFragment(_ value: String) -> String {
        var result = decodeNamedEntities(value)
        result = decodeNumericEntities(result)
        return result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNamedEntities(_ value: String) -> String {
        let replacements = [
            "nbsp": " ", "amp": "&", "lt": "<", "gt": ">",
            "quot": "\"", "apos": "'",
        ]
        guard let expression = try? NSRegularExpression(
            pattern: #"&(nbsp|amp|lt|gt|quot|apos);"#,
            options: .caseInsensitive
        ) else { return value }
        var result = value
        for match in expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ).reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: value),
                  let replacement = replacements[value[nameRange].lowercased()]
            else { continue }
            result.replaceSubrange(wholeRange, with: replacement)
        }
        return result
    }

    private static func decodeNumericEntities(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"&#(?:x([0-9a-fA-F]+)|([0-9]+));"#) else {
            return value
        }
        var result = value
        let matches = expression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: result) else { continue }
            let scalarValue: UInt32?
            if match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: value) {
                scalarValue = UInt32(value[range], radix: 16)
            } else if let range = Range(match.range(at: 2), in: value) {
                scalarValue = UInt32(value[range], radix: 10)
            } else {
                scalarValue = nil
            }
            guard let scalarValue, let scalar = UnicodeScalar(scalarValue),
                  !CharacterSet.controlCharacters.contains(scalar)
            else { continue }
            result.replaceSubrange(wholeRange, with: String(scalar))
        }
        return result
    }
}
