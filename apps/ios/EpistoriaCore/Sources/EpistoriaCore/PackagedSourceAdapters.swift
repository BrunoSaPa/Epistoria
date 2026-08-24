import Foundation
import ZIPFoundation

private struct ArchiveSafetyLimits: Sendable {
    var maximumCompressedBytes: Int
    var maximumEntryCount: Int
    var maximumEntryBytes: UInt64
    var maximumExpandedBytes: UInt64
    var maximumExpansionRatio: UInt64

    static let document = ArchiveSafetyLimits(
        maximumCompressedBytes: 256 * 1_024 * 1_024,
        maximumEntryCount: 20_000,
        maximumEntryBytes: 128 * 1_024 * 1_024,
        maximumExpandedBytes: 1_024 * 1_024 * 1_024,
        maximumExpansionRatio: 200
    )

    static let epub = ArchiveSafetyLimits(
        maximumCompressedBytes: 128 * 1_024 * 1_024,
        maximumEntryCount: 20_000,
        maximumEntryBytes: 64 * 1_024 * 1_024,
        maximumExpandedBytes: 512 * 1_024 * 1_024,
        maximumExpansionRatio: 200
    )
}

/// Reads package entries in memory after enforcing limits that prevent path traversal and ZIP bombs.
private final class BoundedPackage {
    private let archive: Archive
    private let entries: [String: Entry]
    private let limits: ArchiveSafetyLimits

    init(data: Data, limits: ArchiveSafetyLimits) throws {
        guard data.count <= limits.maximumCompressedBytes else { throw SourceAdapterError.tooLarge }
        let opened: Archive
        do { opened = try Archive(data: data, accessMode: .read) }
        catch { throw SourceAdapterError.malformed }

        var indexed: [String: Entry] = [:]
        var expandedBytes: UInt64 = 0
        var count = 0
        for entry in opened {
            count += 1
            guard count <= limits.maximumEntryCount else { throw SourceAdapterError.tooLarge }
            guard entry.type != .symlink, Self.isSafe(path: entry.path) else {
                throw SourceAdapterError.malformed
            }
            guard indexed[entry.path] == nil else { throw SourceAdapterError.malformed }
            guard entry.uncompressedSize <= limits.maximumEntryBytes else {
                throw SourceAdapterError.tooLarge
            }
            let (nextTotal, overflow) = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, nextTotal <= limits.maximumExpandedBytes else {
                throw SourceAdapterError.tooLarge
            }
            expandedBytes = nextTotal
            if entry.uncompressedSize > 0 {
                guard entry.compressedSize > 0 else { throw SourceAdapterError.tooLarge }
                let allowed = entry.compressedSize.multipliedReportingOverflow(
                    by: limits.maximumExpansionRatio
                )
                guard !allowed.overflow, entry.uncompressedSize <= allowed.partialValue else {
                    throw SourceAdapterError.tooLarge
                }
            }
            indexed[entry.path] = entry
        }
        guard !indexed.isEmpty else { throw SourceAdapterError.malformed }
        archive = opened
        entries = indexed
        self.limits = limits
    }

    var paths: [String] { Array(entries.keys) }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    func data(at path: String, maximumBytes: UInt64? = nil) throws -> Data {
        guard let entry = entries[path], entry.type == .file else { throw SourceAdapterError.malformed }
        let maximum = min(maximumBytes ?? limits.maximumEntryBytes, limits.maximumEntryBytes)
        guard entry.uncompressedSize <= maximum, entry.uncompressedSize <= UInt64(Int.max) else {
            throw SourceAdapterError.tooLarge
        }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry, skipCRC32: false) { chunk in
                guard result.count <= Int(maximum) - chunk.count else {
                    throw SourceAdapterError.tooLarge
                }
                result.append(chunk)
            }
        } catch let error as SourceAdapterError {
            throw error
        } catch {
            throw SourceAdapterError.malformed
        }
        guard result.count == Int(entry.uncompressedSize) else { throw SourceAdapterError.malformed }
        return result
    }

    /// Forces CRC validation for every file before the package becomes an accepted Source.
    func validateAllEntries() throws {
        for path in paths.sorted() {
            guard let entry = entries[path], entry.type == .file else { continue }
            var consumed: UInt64 = 0
            do {
                _ = try archive.extract(entry, skipCRC32: false) { chunk in
                    let (next, overflow) = consumed.addingReportingOverflow(UInt64(chunk.count))
                    guard !overflow, next <= entry.uncompressedSize else {
                        throw SourceAdapterError.malformed
                    }
                    consumed = next
                }
            } catch let error as SourceAdapterError {
                throw error
            } catch {
                throw SourceAdapterError.malformed
            }
            guard consumed == entry.uncompressedSize else { throw SourceAdapterError.malformed }
        }
    }

    private static func isSafe(path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, component in
            if component.isEmpty { return index == components.count - 1 }
            return component != "." && component != ".."
        }
    }
}

private final class ReadableXMLCollector: NSObject, XMLParserDelegate {
    private let textElements: Set<String>
    private let breakElements: Set<String>
    private let sectionElement: String?
    private let sectionLabel: String
    private var text = ""
    private var capturingDepth = 0
    private var sectionNumber = 0
    private(set) var failed = false

    init(
        textElements: Set<String>,
        breakElements: Set<String>,
        sectionElement: String? = nil,
        sectionLabel: String = "Section"
    ) {
        self.textElements = textElements
        self.breakElements = breakElements
        self.sectionElement = sectionElement
        self.sectionLabel = sectionLabel
    }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName qName: String?,
        attributes _: [String: String] = [:]
    ) {
        let name = Self.localName(qName ?? elementName)
        if name == sectionElement {
            sectionNumber += 1
            appendBoundary("\n\n\(sectionLabel) \(sectionNumber)\n")
        }
        if textElements.contains(name) { capturingDepth += 1 }
        if name == "tab" { text.append("\t") }
        if name == "br" { appendBoundary("\n") }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if capturingDepth > 0 { text.append(string) }
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.localName(qName ?? elementName)
        if textElements.contains(name) { capturingDepth = max(0, capturingDepth - 1) }
        if breakElements.contains(name) { appendBoundary("\n") }
    }

    func parser(_: XMLParser, parseErrorOccurred _: Error) { failed = true }

    func result() -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendBoundary(_ boundary: String) {
        guard !text.hasSuffix(boundary) else { return }
        text.append(boundary)
    }

    fileprivate static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private func parseReadableXML(
    _ data: Data,
    textElements: Set<String>,
    breakElements: Set<String>,
    sectionElement: String? = nil,
    sectionLabel: String = "Section"
) throws -> String {
    let collector = ReadableXMLCollector(
        textElements: textElements,
        breakElements: breakElements,
        sectionElement: sectionElement,
        sectionLabel: sectionLabel
    )
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = collector
    guard parser.parse(), !collector.failed else { throw SourceAdapterError.malformed }
    return collector.result()
}

private final class PackageContentTypesParser: NSObject, XMLParserDelegate {
    private(set) var contentTypes: Set<String> = []

    func parser(
        _: XMLParser,
        didStartElement _: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if let contentType = attributeDict["ContentType"] { contentTypes.insert(contentType) }
    }
}

private func requirePackageContentType(_ expected: String, in package: BoundedPackage) throws {
    let delegate = PackageContentTypesParser()
    let parser = XMLParser(data: try package.data(at: "[Content_Types].xml"))
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse(), delegate.contentTypes.contains(expected) else {
        throw SourceAdapterError.malformed
    }
}

private final class XMLRootParser: NSObject, XMLParserDelegate {
    private(set) var rootName: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName qName: String?,
        attributes _: [String: String] = [:]
    ) {
        guard rootName == nil else { return }
        rootName = ReadableXMLCollector.localName(qName ?? elementName)
        parser.abortParsing()
    }
}

private func requireXMLRoot(_ expected: String, data: Data) throws {
    let delegate = XMLRootParser()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    _ = parser.parse()
    guard delegate.rootName == expected else { throw SourceAdapterError.malformed }
}

private protocol PackagedDocumentAdapter: SourceAdapter {
    var requiredPaths: Set<String> { get }
    var limits: ArchiveSafetyLimits { get }
    func extractedText(from package: BoundedPackage) throws -> String
}

extension PackagedDocumentAdapter {
    public var maximumBytes: Int { limits.maximumCompressedBytes }

    public func validate(data: Data, filename _: String, mimeType _: String) throws {
        let package = try BoundedPackage(data: data, limits: limits)
        guard requiredPaths.allSatisfy(package.contains) else { throw SourceAdapterError.malformed }
        try package.validateAllEntries()
        let text = try extractedText(from: package)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceAdapterError.containsNoReadableText
        }
    }

    public func extractText(data: Data) throws -> String? {
        let package = try BoundedPackage(data: data, limits: limits)
        guard requiredPaths.allSatisfy(package.contains) else { throw SourceAdapterError.malformed }
        let text = try extractedText(from: package)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceAdapterError.containsNoReadableText
        }
        return text
    }

    public func thumbnail(data _: Data) throws -> Data? { nil }

    public func readableExport(data: Data) throws -> Data {
        guard let text = try extractText(data: data) else { throw SourceAdapterError.containsNoReadableText }
        return Data(text.utf8)
    }
}

public struct DOCXSourceAdapter: PackagedDocumentAdapter {
    public let sourceType = ResourceKind.docx
    public let supportedExtensions: Set<String> = ["docx"]
    fileprivate let requiredPaths: Set<String> = ["[Content_Types].xml", "word/document.xml"]
    fileprivate let limits = ArchiveSafetyLimits.document

    public init() {}

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .docx, mimeType: mimeType)
    }

    fileprivate func extractedText(from package: BoundedPackage) throws -> String {
        try requirePackageContentType(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
            in: package
        )
        return try parseReadableXML(
            package.data(at: "word/document.xml"),
            textElements: ["t"],
            breakElements: ["p", "tr"]
        )
    }
}

public struct PPTXSourceAdapter: PackagedDocumentAdapter {
    public let sourceType = ResourceKind.pptx
    public let supportedExtensions: Set<String> = ["pptx"]
    fileprivate let requiredPaths: Set<String> = [
        "[Content_Types].xml",
        "ppt/presentation.xml",
        "ppt/_rels/presentation.xml.rels",
    ]
    fileprivate let limits = ArchiveSafetyLimits.document

    public init() {}

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .pptx, mimeType: mimeType)
    }

    fileprivate func extractedText(from package: BoundedPackage) throws -> String {
        try requirePackageContentType(
            "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
            in: package
        )
        try requireXMLRoot("presentation", data: package.data(at: "ppt/presentation.xml"))
        let order = try orderedDocumentParts(
            documentData: package.data(at: "ppt/presentation.xml"),
            relationshipsData: package.data(at: "ppt/_rels/presentation.xml.rels"),
            itemElement: "sldId",
            baseDirectory: "ppt",
            package: package
        )
        guard !order.isEmpty else { throw SourceAdapterError.malformed }
        return try order.enumerated().map { index, item in
            let body = try parseReadableXML(
                package.data(at: item.path),
                textElements: ["t"],
                breakElements: ["p"]
            )
            return "Slide \(index + 1)\n\(body)"
        }.joined(separator: "\n\n")
    }
}

public struct ODTSourceAdapter: PackagedDocumentAdapter {
    public let sourceType = ResourceKind.odt
    public let supportedExtensions: Set<String> = ["odt"]
    fileprivate let requiredPaths: Set<String> = ["mimetype", "content.xml"]
    fileprivate let limits = ArchiveSafetyLimits.document

    public init() {}

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .odt, mimeType: mimeType)
    }

    fileprivate func extractedText(from package: BoundedPackage) throws -> String {
        try requireMIME("application/vnd.oasis.opendocument.text", in: package)
        return try parseReadableXML(
            package.data(at: "content.xml"),
            textElements: ["p", "h"],
            breakElements: ["p", "h", "list-item"]
        )
    }
}

public struct ODPSourceAdapter: PackagedDocumentAdapter {
    public let sourceType = ResourceKind.odp
    public let supportedExtensions: Set<String> = ["odp"]
    fileprivate let requiredPaths: Set<String> = ["mimetype", "content.xml"]
    fileprivate let limits = ArchiveSafetyLimits.document

    public init() {}

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .odp, mimeType: mimeType)
    }

    fileprivate func extractedText(from package: BoundedPackage) throws -> String {
        try requireMIME("application/vnd.oasis.opendocument.presentation", in: package)
        return try parseReadableXML(
            package.data(at: "content.xml"),
            textElements: ["p", "h"],
            breakElements: ["p", "h"],
            sectionElement: "page",
            sectionLabel: "Slide"
        )
    }
}

private func requireMIME(_ expected: String, in package: BoundedPackage) throws {
    let data = try package.data(at: "mimetype", maximumBytes: 256)
    guard String(data: data, encoding: .utf8) == expected else { throw SourceAdapterError.malformed }
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    private(set) var rootPath: String?
    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if ReadableXMLCollector.localName(qName ?? elementName) == "rootfile" {
            rootPath = attributeDict["full-path"] ?? attributeDict.first {
                ReadableXMLCollector.localName($0.key) == "full-path"
            }?.value
        }
    }
}

private final class EPUBPackageParser: NSObject, XMLParserDelegate {
    private(set) var manifest: [String: String] = [:]
    private(set) var spine: [String] = []

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch ReadableXMLCollector.localName(qName ?? elementName) {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] { manifest[id] = href }
        case "itemref":
            if let id = attributeDict["idref"] { spine.append(id) }
        default: break
        }
    }
}

public struct EPUBSourceAdapter: PackagedDocumentAdapter {
    public let sourceType = ResourceKind.epub
    public let supportedExtensions: Set<String> = ["epub"]
    fileprivate let requiredPaths: Set<String> = ["mimetype", "META-INF/container.xml"]
    fileprivate let limits = ArchiveSafetyLimits.epub

    public init() {}

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .epub, mimeType: mimeType)
    }

    fileprivate func extractedText(from package: BoundedPackage) throws -> String {
        try requireMIME("application/epub+zip", in: package)
        let containerDelegate = EPUBContainerParser()
        let containerParser = XMLParser(data: try package.data(at: "META-INF/container.xml"))
        containerParser.shouldProcessNamespaces = true
        containerParser.shouldResolveExternalEntities = false
        containerParser.delegate = containerDelegate
        guard containerParser.parse(), let rootPath = containerDelegate.rootPath,
              package.contains(rootPath)
        else { throw SourceAdapterError.malformed }

        let packageDelegate = EPUBPackageParser()
        let packageParser = XMLParser(data: try package.data(at: rootPath))
        packageParser.shouldProcessNamespaces = true
        packageParser.shouldResolveExternalEntities = false
        packageParser.delegate = packageDelegate
        guard packageParser.parse(), !packageDelegate.spine.isEmpty else {
            throw SourceAdapterError.malformed
        }
        let base = (rootPath as NSString).deletingLastPathComponent
        return try packageDelegate.spine.enumerated().map { index, itemID in
            guard let href = packageDelegate.manifest[itemID] else { throw SourceAdapterError.malformed }
            let decoded = href.removingPercentEncoding ?? href
            let path = base.isEmpty ? decoded : "\(base)/\(decoded)"
            guard package.contains(path) else { throw SourceAdapterError.malformed }
            let body = try parseReadableXML(
                package.data(at: path),
                textElements: ["title", "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "td", "th"],
                breakElements: ["title", "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr"]
            )
            return "Chapter \(index + 1)\n\(body)"
        }.joined(separator: "\n\n")
    }
}

private final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var values: [String] = []
    private var current = ""
    private var capturesText = false
    private var insideItem = false

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName qName: String?, attributes _: [String: String] = [:]) {
        let name = ReadableXMLCollector.localName(qName ?? elementName)
        if name == "si" { insideItem = true; current = "" }
        if name == "t", insideItem { capturesText = true }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if capturesText { current.append(string) }
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName qName: String?) {
        let name = ReadableXMLCollector.localName(qName ?? elementName)
        if name == "t" { capturesText = false }
        if name == "si" { values.append(current); insideItem = false }
    }
}

private final class XLSXWorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var rows: [[String]] = []
    private var row: [String] = []
    private var cellType: String?
    private var value = ""
    private var capturesValue = false

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch ReadableXMLCollector.localName(qName ?? elementName) {
        case "row": row = []
        case "c": cellType = attributeDict["t"]; value = ""
        case "v", "t": capturesValue = true
        default: break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if capturesValue { value.append(string) }
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName qName: String?) {
        switch ReadableXMLCollector.localName(qName ?? elementName) {
        case "v", "t": capturesValue = false
        case "c":
            if cellType == "s", let index = Int(value), sharedStrings.indices.contains(index) {
                row.append(sharedStrings[index])
            } else if cellType == "b" {
                row.append(value == "1" ? "TRUE" : "FALSE")
            } else {
                row.append(value)
            }
        case "row": rows.append(row)
        default: break
        }
    }
}

public struct XLSXSourceAdapter: PackagedDocumentAdapter {
    public let sourceType = ResourceKind.xlsx
    public let supportedExtensions: Set<String> = ["xlsx"]
    fileprivate let requiredPaths: Set<String> = [
        "[Content_Types].xml",
        "xl/workbook.xml",
        "xl/_rels/workbook.xml.rels",
    ]
    fileprivate let limits = ArchiveSafetyLimits.document

    public init() {}

    public func renderDescriptor(mimeType: String) -> SourceRenderDescriptor {
        SourceRenderDescriptor(kind: .xlsx, mimeType: mimeType)
    }

    fileprivate func extractedText(from package: BoundedPackage) throws -> String {
        try requirePackageContentType(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
            in: package
        )
        try requireXMLRoot("workbook", data: package.data(at: "xl/workbook.xml"))
        var sharedStrings: [String] = []
        if package.contains("xl/sharedStrings.xml") {
            let delegate = XLSXSharedStringsParser()
            let parser = XMLParser(data: try package.data(at: "xl/sharedStrings.xml"))
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse() else { throw SourceAdapterError.malformed }
            sharedStrings = delegate.values
        }
        let sheets = try orderedDocumentParts(
            documentData: package.data(at: "xl/workbook.xml"),
            relationshipsData: package.data(at: "xl/_rels/workbook.xml.rels"),
            itemElement: "sheet",
            baseDirectory: "xl",
            package: package
        )
        guard !sheets.isEmpty else { throw SourceAdapterError.malformed }
        return try sheets.enumerated().map { index, item in
            let delegate = XLSXWorksheetParser(sharedStrings: sharedStrings)
            let parser = XMLParser(data: try package.data(at: item.path))
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse() else { throw SourceAdapterError.malformed }
            let rows = delegate.rows.map { row in
                row.map {
                    $0.replacingOccurrences(of: "\t", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                }.joined(separator: "\t")
            }.joined(separator: "\n")
            let title = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Sheet \(index + 1)"
            return "\(heading)\n\(rows)"
        }.joined(separator: "\n\n")
    }
}

private struct OrderedDocumentPart {
    var name: String?
    var relationshipID: String
    var path: String
}

private final class OrderedDocumentParser: NSObject, XMLParserDelegate {
    private let itemElement: String
    private(set) var items: [(name: String?, relationshipID: String)] = []

    init(itemElement: String) { self.itemElement = itemElement }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard ReadableXMLCollector.localName(qName ?? elementName) == itemElement else { return }
        let relationshipID = attributeDict.first {
            ReadableXMLCollector.localName($0.key).lowercased() == "id"
                && $0.value.lowercased().hasPrefix("rid")
        }?.value
        if let relationshipID {
            items.append((attributeDict["name"], relationshipID))
        }
    }
}

private final class PackageRelationshipsParser: NSObject, XMLParserDelegate {
    private(set) var targets: [String: String] = [:]

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard ReadableXMLCollector.localName(qName ?? elementName) == "Relationship",
              attributeDict["TargetMode"]?.lowercased() != "external",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"]
        else { return }
        targets[id] = target
    }
}

private func orderedDocumentParts(
    documentData: Data,
    relationshipsData: Data,
    itemElement: String,
    baseDirectory: String,
    package: BoundedPackage
) throws -> [OrderedDocumentPart] {
    let documentDelegate = OrderedDocumentParser(itemElement: itemElement)
    let documentParser = XMLParser(data: documentData)
    documentParser.shouldProcessNamespaces = true
    documentParser.shouldResolveExternalEntities = false
    documentParser.delegate = documentDelegate
    guard documentParser.parse(), !documentDelegate.items.isEmpty else {
        throw SourceAdapterError.malformed
    }

    let relationshipsDelegate = PackageRelationshipsParser()
    let relationshipsParser = XMLParser(data: relationshipsData)
    relationshipsParser.shouldProcessNamespaces = true
    relationshipsParser.shouldResolveExternalEntities = false
    relationshipsParser.delegate = relationshipsDelegate
    guard relationshipsParser.parse() else { throw SourceAdapterError.malformed }

    return try documentDelegate.items.map { item in
        guard let target = relationshipsDelegate.targets[item.relationshipID] else {
            throw SourceAdapterError.malformed
        }
        let cleanTarget = (target.removingPercentEncoding ?? target)
            .split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        guard !cleanTarget.isEmpty,
              !cleanTarget.hasPrefix("/"),
              !cleanTarget.contains("\\"),
              !cleanTarget.split(separator: "/").contains("..")
        else { throw SourceAdapterError.malformed }
        let path = "\(baseDirectory)/\(cleanTarget)"
        guard package.contains(path) else { throw SourceAdapterError.malformed }
        return OrderedDocumentPart(
            name: item.name,
            relationshipID: item.relationshipID,
            path: path
        )
    }
}
