import Foundation
import UniformTypeIdentifiers

public struct SourceRenderDescriptor: Equatable, Sendable {
    public var kind: SourceKind
    public var mimeType: String
    public var prefersMonospacedText: Bool

    public init(kind: SourceKind, mimeType: String, prefersMonospacedText: Bool = false) {
        self.kind = kind
        self.mimeType = mimeType
        self.prefersMonospacedText = prefersMonospacedText
    }
}

public protocol SourceAdapter: Sendable {
    var sourceType: SourceKind { get }
    var supportedExtensions: Set<String> { get }
    var maximumBytes: Int { get }
    func validate(data: Data, filename: String, mimeType: String) throws
    func renderDescriptor(mimeType: String) -> SourceRenderDescriptor
    func extractText(data: Data) throws -> String?
    func thumbnail(data: Data) throws -> Data?
    func readableExport(data: Data) throws -> Data
}

public protocol DecoderValidatedSourceAdapter: SourceAdapter {
    func validateWithDecoder(data: Data, filename: String, mimeType: String) async throws
}

public extension SourceAdapter {
    func validateForImport(data: Data, filename: String, mimeType: String) async throws {
        if let decoderValidated = self as? any DecoderValidatedSourceAdapter {
            try await decoderValidated.validateWithDecoder(
                data: data,
                filename: filename,
                mimeType: mimeType
            )
        } else {
            try validate(data: data, filename: filename, mimeType: mimeType)
        }
    }
}

public enum SourceAdapterError: Error, Equatable, LocalizedError {
    case unsupportedType
    case malformed
    case tooLarge
    case containsNoReadableText

    public var errorDescription: String? {
        switch self {
        case .unsupportedType: "This source type is not supported yet."
        case .malformed: "The source is malformed. No Library record was created."
        case .tooLarge: "The source is too large to import safely."
        case .containsNoReadableText: "The source contains no readable text."
        }
    }
}

public struct PlainTextSourceAdapter: SourceAdapter {
    public let sourceType: SourceKind
    public let supportedExtensions: Set<String>
    public let maximumBytes = 32 * 1_024 * 1_024

    public init(sourceType: SourceKind, extensions: Set<String>) {
        self.sourceType = sourceType
        supportedExtensions = extensions
    }

    public func validate(data: Data, filename _: String, mimeType _: String) throws {
        guard data.count <= maximumBytes else { throw SourceAdapterError.tooLarge }
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SourceAdapterError.containsNoReadableText }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SourceAdapterError.malformed
        }
    }

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(
            kind: sourceType,
            mimeType: mimeType,
            prefersMonospacedText: sourceType == .markdown
        )
    }

    public func extractText(data: Data) throws -> String? {
        guard let text = String(data: data, encoding: .utf8) else { throw SourceAdapterError.malformed }
        return text
    }

    public func thumbnail(data _: Data) throws -> Data? { nil }
    public func readableExport(data: Data) throws -> Data { data }
}

public struct CSVSourceDocument: Equatable, Sendable {
    public var rows: [[String]]

    public init(rows: [[String]]) {
        self.rows = rows
    }

    public var maximumColumnCount: Int { rows.map(\.count).max() ?? 0 }
}

public struct CSVSourceAdapter: SourceAdapter {
    public let sourceType = SourceKind.csv
    public let supportedExtensions: Set<String> = ["csv"]
    public let maximumBytes = 32 * 1_024 * 1_024

    public init() {}

    public func validate(data: Data, filename _: String, mimeType _: String) throws {
        guard data.count <= maximumBytes else { throw SourceAdapterError.tooLarge }
        let document = try parse(data: data)
        guard document.rows.contains(where: { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) else { throw SourceAdapterError.containsNoReadableText }
    }

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .csv, mimeType: mimeType)
    }

    public func extractText(data: Data) throws -> String? {
        let document = try parse(data: data)
        return document.rows.map { row in
            row.map {
                $0.replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    public func thumbnail(data _: Data) throws -> Data? { nil }
    public func readableExport(data: Data) throws -> Data { data }

    public func parse(data: Data) throws -> CSVSourceDocument {
        guard data.count <= maximumBytes else { throw SourceAdapterError.tooLarge }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard let decoded = String(data: bytes, encoding: .utf8),
              !decoded.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw SourceAdapterError.malformed }
        let text = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var closedQuote = false
        var index = text.startIndex

        func finishField() throws {
            guard row.count < 10_000 else { throw SourceAdapterError.tooLarge }
            row.append(field)
            field = ""
            closedQuote = false
        }

        func finishRow() throws {
            try finishField()
            guard rows.count < 100_000 else { throw SourceAdapterError.tooLarge }
            rows.append(row)
            row = []
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if isQuoted {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    isQuoted = false
                    closedQuote = true
                } else {
                    field.append(character)
                }
            } else if closedQuote {
                if character == "," {
                    try finishField()
                } else if character == "\n" {
                    try finishRow()
                } else if character == "\r" {
                    if next < text.endIndex, text[next] == "\n" { index = next }
                    try finishRow()
                } else {
                    throw SourceAdapterError.malformed
                }
            } else if character == "\"" {
                guard field.isEmpty else { throw SourceAdapterError.malformed }
                isQuoted = true
            } else if character == "," {
                try finishField()
            } else if character == "\n" {
                try finishRow()
            } else if character == "\r" {
                if next < text.endIndex, text[next] == "\n" { index = next }
                try finishRow()
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        guard !isQuoted else { throw SourceAdapterError.malformed }
        if !field.isEmpty || !row.isEmpty || closedQuote { try finishRow() }
        return CSVSourceDocument(rows: rows)
    }
}

public struct SourceAdapterRegistry: Sendable {
    private let adapters: [any SourceAdapter] = [
        PlainTextSourceAdapter(sourceType: .pastedText, extensions: ["txt"]),
        PlainTextSourceAdapter(sourceType: .markdown, extensions: ["md", "markdown"]),
        HTMLSourceAdapter(),
        WebSnapshotSourceAdapter(),
        CSVSourceAdapter(),
        EPUBSourceAdapter(),
        DOCXSourceAdapter(),
        ODTSourceAdapter(),
        PPTXSourceAdapter(),
        ODPSourceAdapter(),
        XLSXSourceAdapter(),
        AudioSourceAdapter(),
        VideoSourceAdapter(),
        GoogleWorkspaceSourceAdapter(kind: .document),
        GoogleWorkspaceSourceAdapter(kind: .slides),
        GoogleWorkspaceSourceAdapter(kind: .sheet),
    ]

    public init() {}

    public func adapter(for filename: String) throws -> any SourceAdapter {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard let adapter = adapters.first(where: { $0.supportedExtensions.contains(ext) }) else {
            throw SourceAdapterError.unsupportedType
        }
        return adapter
    }

    public func adapter(for sourceType: SourceKind) throws -> any SourceAdapter {
        guard let adapter = adapters.first(where: { $0.sourceType == sourceType }) else {
            throw SourceAdapterError.unsupportedType
        }
        return adapter
    }

    public var supportedExtensions: Set<String> {
        adapters.reduce(into: Set<String>()) { $0.formUnion($1.supportedExtensions) }
    }
}

@available(*, deprecated, renamed: "SourceAdapterRegistry")
public typealias PhaseOneSourceAdapterRegistry = SourceAdapterRegistry
