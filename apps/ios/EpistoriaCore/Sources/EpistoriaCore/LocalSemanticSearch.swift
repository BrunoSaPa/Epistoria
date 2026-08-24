import Foundation
import NaturalLanguage

struct LocalSemanticEmbeddingModel: Equatable, Hashable, Sendable {
    var language: String
    var revision: Int
    var dimension: Int
}

protocol LocalSemanticEmbeddingProviding: Sendable {
    var isAvailable: Bool { get }
    func model(for text: String) -> LocalSemanticEmbeddingModel?
    func vector(for text: String, model: LocalSemanticEmbeddingModel) -> [Float]?
}

struct AppleLocalSemanticEmbeddingProvider: LocalSemanticEmbeddingProviding {
    private static let candidateLanguages: [NLLanguage] = [
        .english, .spanish, .french, .german, .italian, .portuguese,
    ]

    var isAvailable: Bool {
        Self.candidateLanguages.contains {
            NLEmbedding.sentenceEmbedding(for: $0) != nil
        }
    }

    func model(for text: String) -> LocalSemanticEmbeddingModel? {
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)
        let languages = ([detected].compactMap(\ .self) + Self.candidateLanguages).uniqued()
        for language in languages {
            guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { continue }
            return LocalSemanticEmbeddingModel(
                language: language.rawValue,
                revision: embedding.revision,
                dimension: embedding.dimension
            )
        }
        return nil
    }

    func vector(for text: String, model: LocalSemanticEmbeddingModel) -> [Float]? {
        let language = NLLanguage(rawValue: model.language)
        guard let embedding = NLEmbedding.sentenceEmbedding(
            for: language,
            revision: model.revision
        ), embedding.dimension == model.dimension,
           let values = embedding.vector(for: text)
        else { return nil }
        return LocalSemanticSearch.normalized(values.map(Float.init))
    }
}

enum LocalSemanticSearch {
    static let engineVersion = 1
    static let maximumChunksPerDocument = 12
    static let maximumChunkCharacters = 900
    static let maximumSnippetCharacters = 360
    static let minimumSimilarity = 0.68

    struct Chunk: Equatable, Sendable {
        var text: String
        var snippet: String
    }

    static func chunks(for document: SearchDocument) -> [Chunk] {
        let title = normalizedWhitespace(document.title).prefixCharacters(300)
        let body = normalizedLines(document.body)
        let units = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { paragraph in
                String(paragraph).chunks(maximumCharacters: maximumChunkCharacters)
            }
        let selected = evenlySelected(units, limit: maximumChunksPerDocument)
        if selected.isEmpty {
            guard !title.isEmpty else { return [] }
            return [Chunk(text: title, snippet: title)]
        }
        return selected.map { unit in
            let snippet = unit.prefixCharacters(maximumSnippetCharacters)
            let text = title.isEmpty ? unit : "\(title)\n\(unit)"
            return Chunk(text: text, snippet: snippet.isEmpty ? title : snippet)
        }
    }

    static func normalized(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty, values.count <= 2_048,
              values.allSatisfy(\ .isFinite)
        else { return nil }
        let magnitude = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return values.map { Float(Double($0) / magnitude) }
    }

    static func similarity(_ left: [Float], _ right: [Float]) -> Double? {
        guard left.count == right.count, !left.isEmpty else { return nil }
        let value = zip(left, right).reduce(0.0) {
            $0 + Double($1.0) * Double($1.1)
        }
        guard value.isFinite else { return nil }
        return min(1, max(-1, value))
    }

    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard dimension > 0, dimension <= 2_048,
              data.count == dimension * MemoryLayout<UInt32>.size
        else { return nil }
        return data.withUnsafeBytes { bytes in
            (0 ..< dimension).map { index in
                let bits = bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<UInt32>.size,
                    as: UInt32.self
                )
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \ .isWhitespace).joined(separator: " ")
    }

    private static func normalizedLines(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .map(normalizedWhitespace)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func evenlySelected(_ values: [String], limit: Int) -> [String] {
        guard values.count > limit, limit > 1 else { return Array(values.prefix(limit)) }
        let last = values.count - 1
        let indexes = (0 ..< limit).map { Int((Double($0) * Double(last) / Double(limit - 1)).rounded()) }
        return indexes.uniqued().map { values[$0] }
    }
}

private extension String {
    func prefixCharacters(_ limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit))
    }

    func chunks(maximumCharacters: Int) -> [String] {
        guard count > maximumCharacters else { return [self] }
        var result: [String] = []
        var start = startIndex
        while start < endIndex {
            let proposedEnd = index(start, offsetBy: maximumCharacters, limitedBy: endIndex)
                ?? endIndex
            var end = proposedEnd
            if proposedEnd < endIndex,
               let boundary = self[start ..< proposedEnd].lastIndex(where: \ .isWhitespace),
               distance(from: start, to: boundary) >= maximumCharacters / 2
            {
                end = boundary
            }
            let chunk = self[start ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            start = end
            while start < endIndex, self[start].isWhitespace {
                formIndex(after: &start)
            }
        }
        return result
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
