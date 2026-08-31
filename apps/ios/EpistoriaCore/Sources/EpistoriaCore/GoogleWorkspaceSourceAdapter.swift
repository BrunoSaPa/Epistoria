import Foundation

public enum GoogleWorkspaceDocumentKind: String, CaseIterable, Codable, Sendable {
    case document = "DOCUMENT"
    case slides = "SLIDES"
    case sheet = "SHEET"

    public var sourceType: SourceKind {
        switch self {
        case .document: .googleDocument
        case .slides: .googleSlides
        case .sheet: .googleSheet
        }
    }

    public var displayName: String {
        switch self {
        case .document: "Google Doc"
        case .slides: "Google Slides"
        case .sheet: "Google Sheet"
        }
    }

    fileprivate var pathComponent: String {
        switch self {
        case .document: "document"
        case .slides: "presentation"
        case .sheet: "spreadsheets"
        }
    }

    var exportFormat: String {
        switch self {
        case .document: "docx"
        case .slides: "pptx"
        case .sheet: "xlsx"
        }
    }

    fileprivate var exportMIMEType: String {
        switch self {
        case .document:
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .slides:
            "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .sheet:
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
    }

    fileprivate var internalExtension: String {
        switch self {
        case .document: "epistoriagdoc"
        case .slides: "epistoriagslides"
        case .sheet: "epistoriagsheet"
        }
    }

    fileprivate var packagedAdapter: any SourceAdapter {
        switch self {
        case .document: DOCXSourceAdapter()
        case .slides: PPTXSourceAdapter()
        case .sheet: XLSXSourceAdapter()
        }
    }
}

public extension SourceKind {
    var isGoogleWorkspaceSource: Bool {
        self == .googleDocument || self == .googleSlides || self == .googleSheet
    }
}

public struct GoogleWorkspaceReference: Equatable, Sendable {
    public var kind: GoogleWorkspaceDocumentKind
    public var fileID: String
    public var canonicalURL: URL
    public var exportURL: URL

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "docs.google.com",
              components.user == nil,
              components.password == nil
        else { throw GoogleWorkspaceCaptureError.invalidURL }

        let path = components.path.split(separator: "/").map(String.init)
        guard path.count >= 3, path[1] == "d" else {
            throw GoogleWorkspaceCaptureError.invalidURL
        }
        let resolvedKind: GoogleWorkspaceDocumentKind
        switch path[0] {
        case "document": resolvedKind = .document
        case "presentation": resolvedKind = .slides
        case "spreadsheets": resolvedKind = .sheet
        default: throw GoogleWorkspaceCaptureError.unsupportedDocument
        }
        let resolvedID = path[2]
        guard !resolvedID.isEmpty,
              resolvedID.count <= 256,
              resolvedID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              })
        else { throw GoogleWorkspaceCaptureError.invalidURL }

        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "docs.google.com"
        canonical.path = "/\(resolvedKind.pathComponent)/d/\(resolvedID)"
        let resourceKeys = (components.queryItems ?? []).filter {
            $0.name.lowercased() == "resourcekey"
        }
        guard resourceKeys.count <= 1 else { throw GoogleWorkspaceCaptureError.invalidURL }
        let resourceKey = try resourceKeys.first.flatMap { item -> String? in
            guard let value = item.value,
                  !value.isEmpty,
                  value.count <= 512,
                  value.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
                  })
            else { throw GoogleWorkspaceCaptureError.invalidURL }
            return value
        }
        if let resourceKey {
            canonical.queryItems = [URLQueryItem(name: "resourcekey", value: resourceKey)]
        }
        guard let canonicalURL = canonical.url else {
            throw GoogleWorkspaceCaptureError.invalidURL
        }
        var export = canonical
        export.path += "/export"
        export.queryItems = [URLQueryItem(name: "format", value: resolvedKind.exportFormat)]
        if let resourceKey {
            export.queryItems?.append(URLQueryItem(name: "resourcekey", value: resourceKey))
        }
        guard let exportURL = export.url else {
            throw GoogleWorkspaceCaptureError.invalidURL
        }

        kind = resolvedKind
        fileID = resolvedID
        self.canonicalURL = canonicalURL
        self.exportURL = exportURL
    }
}

public struct GoogleWorkspaceSnapshot: Equatable, Sendable {
    public var kind: GoogleWorkspaceDocumentKind
    public var canonicalURL: URL
    public var capturedURL: URL
    public var mimeType: String
    public var title: String
    public var data: Data
    public var readableText: String

    public init(
        kind: GoogleWorkspaceDocumentKind,
        canonicalURL: URL,
        capturedURL: URL,
        mimeType: String,
        title: String,
        data: Data,
        readableText: String
    ) {
        self.kind = kind
        self.canonicalURL = canonicalURL
        self.capturedURL = capturedURL
        self.mimeType = mimeType
        self.title = title
        self.data = data
        self.readableText = readableText
    }
}

public enum GoogleWorkspaceCaptureError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedDocument
    case accessDenied
    case httpStatus(Int)
    case tooLarge
    case networkUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a complete Google Docs, Slides, or Sheets share link."
        case .unsupportedDocument:
            "This Google file type is not supported. Use a Google Doc, Slides presentation, or Sheet."
        case .accessDenied:
            "Google did not provide the file. Allow anyone with the link to view it, then try again."
        case let .httpStatus(status):
            "Google returned HTTP status \(status). No Source was created."
        case .tooLarge:
            "The Google file is too large to capture safely."
        case .networkUnavailable:
            "The Google file could not be reached. Check the connection and try again."
        }
    }
}

public protocol GoogleWorkspaceCapturing: Sendable {
    func capture(url: URL) async throws -> GoogleWorkspaceSnapshot
}

public struct GoogleWorkspaceCaptureService: GoogleWorkspaceCapturing, Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
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

    public func capture(url: URL) async throws -> GoogleWorkspaceSnapshot {
        let reference = try GoogleWorkspaceReference(url: url)
        let adapter = GoogleWorkspaceSourceAdapter(kind: reference.kind)
        var request = URLRequest(url: reference.exportURL)
        request.httpMethod = "GET"
        request.setValue(reference.kind.exportMIMEType, forHTTPHeaderField: "Accept")
        request.setValue("Epistoria/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GoogleWorkspaceCaptureError.networkUnavailable
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw GoogleWorkspaceCaptureError.accessDenied
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw GoogleWorkspaceCaptureError.httpStatus(http.statusCode)
            }
            guard let finalURL = http.url,
                  finalURL.scheme?.lowercased() == "https",
                  finalURL.user == nil,
                  finalURL.password == nil
            else { throw GoogleWorkspaceCaptureError.networkUnavailable }
            let responseMIME = (http.mimeType ?? "application/octet-stream").lowercased()
            if responseMIME == "text/html" || responseMIME == "application/xhtml+xml" {
                throw GoogleWorkspaceCaptureError.accessDenied
            }
            if http.expectedContentLength > Int64(adapter.maximumBytes) {
                throw GoogleWorkspaceCaptureError.tooLarge
            }

            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), adapter.maximumBytes))
            }
            for try await byte in bytes {
                guard data.count < adapter.maximumBytes else {
                    throw GoogleWorkspaceCaptureError.tooLarge
                }
                data.append(byte)
            }
            try adapter.validate(
                data: data,
                filename: "export.\(reference.kind.exportFormat)",
                mimeType: responseMIME
            )
            let readableText = try adapter.extractText(data: data) ?? ""
            let suggestedTitle = response.suggestedFilename.flatMap { filename -> String? in
                let value = URL(fileURLWithPath: filename)
                    .deletingPathExtension().lastPathComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.lowercased() != "export" else { return nil }
                return value
            }
            let rawTitle = suggestedTitle ?? reference.kind.displayName
            let title = String(
                rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)
            )
            return GoogleWorkspaceSnapshot(
                kind: reference.kind,
                canonicalURL: reference.canonicalURL,
                capturedURL: reference.exportURL,
                mimeType: reference.kind.exportMIMEType,
                title: title.isEmpty ? reference.kind.displayName : title,
                data: data,
                readableText: readableText
            )
        } catch let error as GoogleWorkspaceCaptureError {
            throw error
        } catch let error as SourceAdapterError {
            if error == .tooLarge { throw GoogleWorkspaceCaptureError.tooLarge }
            throw error
        } catch {
            throw GoogleWorkspaceCaptureError.networkUnavailable
        }
    }
}

public struct GoogleWorkspaceSourceAdapter: SourceAdapter {
    public let kind: GoogleWorkspaceDocumentKind

    public init(kind: GoogleWorkspaceDocumentKind) {
        self.kind = kind
    }

    public var sourceType: SourceKind { kind.sourceType }
    public var supportedExtensions: Set<String> { [kind.internalExtension] }
    public var maximumBytes: Int { kind.packagedAdapter.maximumBytes }

    public func validate(data: Data, filename _: String, mimeType _: String) throws {
        try kind.packagedAdapter.validate(
            data: data,
            filename: "export.\(kind.exportFormat)",
            mimeType: kind.exportMIMEType
        )
    }

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: sourceType, mimeType: mimeType)
    }

    public func extractText(data: Data) throws -> String? {
        try kind.packagedAdapter.extractText(data: data)
    }

    public func thumbnail(data: Data) throws -> Data? {
        try kind.packagedAdapter.thumbnail(data: data)
    }

    public func readableExport(data: Data) throws -> Data {
        try kind.packagedAdapter.readableExport(data: data)
    }
}
