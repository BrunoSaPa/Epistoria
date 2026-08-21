import Foundation
import UniformTypeIdentifiers

public struct SourceRenderDescriptor: Equatable, Sendable {
    public var kind: ResourceKind
    public var mimeType: String
    public var prefersMonospacedText: Bool

    public init(kind: ResourceKind, mimeType: String, prefersMonospacedText: Bool = false) {
        self.kind = kind
        self.mimeType = mimeType
        self.prefersMonospacedText = prefersMonospacedText
    }
}

public protocol SourceAdapter: Sendable {
    var sourceType: ResourceKind { get }
    var supportedExtensions: Set<String> { get }
    var maximumBytes: Int { get }
    func validate(data: Data, filename: String, mimeType: String) throws
    func renderDescriptor(mimeType: String) -> SourceRenderDescriptor
    func extractText(data: Data) throws -> String?
    func thumbnail(data: Data) throws -> Data?
    func readableExport(data: Data) throws -> Data
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
    public let sourceType: ResourceKind
    public let supportedExtensions: Set<String>
    public let maximumBytes = 32 * 1_024 * 1_024

    public init(sourceType: ResourceKind, extensions: Set<String>) {
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

public struct PhaseOneSourceAdapterRegistry: Sendable {
    private let adapters: [any SourceAdapter] = [
        PlainTextSourceAdapter(sourceType: .pastedText, extensions: ["txt"]),
        PlainTextSourceAdapter(sourceType: .markdown, extensions: ["md", "markdown"]),
        PlainTextSourceAdapter(sourceType: .html, extensions: ["html", "htm"]),
    ]

    public init() {}

    public func adapter(for filename: String) throws -> any SourceAdapter {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard let adapter = adapters.first(where: { $0.supportedExtensions.contains(ext) }) else {
            throw SourceAdapterError.unsupportedType
        }
        return adapter
    }

    public var supportedExtensions: Set<String> {
        adapters.reduce(into: Set<String>()) { $0.formUnion($1.supportedExtensions) }
    }
}
