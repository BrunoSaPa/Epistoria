import EpistoriaCore
import SwiftUI

struct NoteFindMatch: Identifiable {
    enum Origin {
        case written
        case recognized(image: Bool, accepted: Bool)
        case corrected

        var label: String {
            switch self {
            case .written: "Written text"
            case let .recognized(image, accepted):
                "Recognized from \(image ? "image" : "handwriting") · \(accepted ? "Accepted" : "Unreviewed")"
            case .corrected: "Corrected by you"
            }
        }

        var symbol: String {
            switch self {
            case .written: "textformat"
            case .recognized: "text.viewfinder"
            case .corrected: "checkmark.circle"
            }
        }
    }

    let id: String
    let blockId: UUID
    let pageIndex: Int
    let text: String
    let origin: Origin
    let rectangles: [AnnotationRectangle]
}

struct NoteFindInNoteView: View {
    let pages: [IdentifiedPayload<NotePagePayload>]
    let blocks: [IdentifiedPayload<NoteBlockPayload>]
    let artifacts: [IdentifiedPayload<OCRArtifactPayload>]
    let store: EpistoriaStore?
    let onOpen: (NoteFindMatch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var correctedRegions: [UUID: [ResolvedOCRRegion]] = [:]
    @State private var correctionStatus = "Loading recognition…"

    var body: some View {
        let matches = NoteFindSearch.matches(query: query, pages: pages, blocks: blocks,
            artifacts: artifacts.filter { correctedRegions[$0.id] != nil }, correctedRegions: correctedRegions)
        NavigationStack {
            List {
                if !correctionStatus.isEmpty {
                    Text(correctionStatus).font(.caption).foregroundStyle(EpistoriaDesign.mutedInk)
                }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Find in Note",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Search typed text, equations, and locally recognized handwriting.")
                    )
                    .listRowBackground(Color.clear)
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("note.find.empty")
                } else {
                    ForEach(matches) { match in
                        Button {
                            onOpen(match)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(pageColor(at: match.pageIndex))
                                    Text("\(match.pageIndex + 1)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Color.black.opacity(0.64))
                                }
                                .frame(width: 42, height: 56)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.black.opacity(0.14), lineWidth: 0.5)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(highlightedSnippet(match.text))
                                        .font(.body)
                                        .foregroundStyle(EpistoriaDesign.ink)
                                        .lineLimit(3)
                                    Label(match.origin.label, systemImage: match.origin.symbol)
                                        .font(.caption)
                                        .foregroundStyle(EpistoriaDesign.mutedInk)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens page \(match.pageIndex + 1) and highlights this match")
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Find text or handwriting")
            .navigationTitle("Find in Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            var failed = false
            for artifact in artifacts where artifact.payload.state == .current
                && artifact.payload.reviewState != .rejected {
                guard !Task.isCancelled else { return }
                do {
                    guard let store else { failed = true; continue }
                    let regions = try await store.resolvedOCRRegions(artifactId: artifact.id)
                    guard !Task.isCancelled else { return }
                    correctedRegions[artifact.id] = regions
                } catch { failed = true }
            }
            correctionStatus = failed ? "Some recognition could not be loaded. Close Find and try again." : ""
        }
    }

    private func pageColor(at index: Int) -> Color {
        guard pages.indices.contains(index) else { return .white }
        return pages[index].payload.configuration.paperColor.swiftUIColor
    }

    private func highlightedSnippet(_ text: String) -> AttributedString {
        let value = NoteFindSearch.snippet(text, query: query)
        var result = AttributedString(value)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = value.startIndex
        while !needle.isEmpty, start < value.endIndex,
              let range = value.range(of: needle, options: NoteFindSearch.options,
                  range: start..<value.endIndex, locale: .current) {
            if let lower = AttributedString.Index(range.lowerBound, within: result),
               let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].font = .body.bold()
                result[lower..<upper].backgroundColor = Color.primary.opacity(0.12)
            }
            start = range.upperBound
        }
        return result
    }
}

enum NoteFindSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func matches(query: String, pages: [IdentifiedPayload<NotePagePayload>],
        blocks: [IdentifiedPayload<NoteBlockPayload>], artifacts: [IdentifiedPayload<OCRArtifactPayload>],
        correctedRegions: [UUID: [ResolvedOCRRegion]] = [:]) -> [NoteFindMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let activeBlocks = blocks.filter { !$0.payload.tombstone }
        let blocksById = Dictionary(activeBlocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func pageIndex(for block: NoteBlockPayload) -> Int? {
            guard let pageId = block.pageId else { return pages.isEmpty ? 0 : nil }
            return pages.firstIndex { $0.id == pageId && $0.payload.trashedAt == nil }
        }
        var values: [NoteFindMatch] = []
        for block in activeBlocks {
            guard let index = pageIndex(for: block.payload) else { continue }
            let text = block.payload.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.range(of: needle, options: options, locale: .current) != nil {
                values.append(NoteFindMatch(
                    id: "block:\(block.id.uuidString)",
                    blockId: block.id,
                    pageIndex: index,
                    text: text,
                    origin: .written,
                    rectangles: []
                ))
            }
        }
        for artifact in artifacts
        where artifact.payload.state == .current && artifact.payload.reviewState != .rejected {
            guard let block = blocksById[artifact.payload.targetId],
                  artifact.payload.targetKind != .sourcePage,
                  block.payload.ocrInputRevision == artifact.payload.inputRevision,
                  let index = pageIndex(for: block.payload)
            else { continue }
            let regions: [ResolvedOCRRegion]
            if let resolved = correctedRegions[artifact.id] {
                regions = resolved
            } else {
                guard artifact.payload.reviewState != .edited else { continue }
                regions = artifact.payload.response.regions.map {
                    ResolvedOCRRegion(region: $0, content: $0.latex?.isEmpty == false ? $0.latex! : $0.text)
                }
            }
            for region in regions {
                let text = region.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.range(of: needle, options: options, locale: .current) != nil else { continue }
                values.append(NoteFindMatch(
                    id: "ocr:\(artifact.id.uuidString):\(region.region.id.uuidString)",
                    blockId: block.id,
                    pageIndex: index,
                    text: text,
                    origin: artifact.payload.reviewState == .edited
                        || region.content != (region.region.latex ?? region.region.text) ? .corrected : .recognized(
                        image: artifact.payload.targetKind == .image,
                        accepted: artifact.payload.reviewState == .accepted),
                    rectangles: region.region.rectangles
                ))
            }
        }
        return values.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            if $0.origin.sortOrder != $1.origin.sortOrder { return $0.origin.sortOrder < $1.origin.sortOrder }
            return $0.id < $1.id
        }
    }

    static func snippet(_ text: String, query: String) -> String {
        let value = text.replacingOccurrences(of: "\n", with: " ")
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let range = value.range(of: needle, options: options, locale: .current) else {
            return String(value.prefix(180))
        }
        let start = value.index(range.lowerBound, offsetBy: -55, limitedBy: value.startIndex) ?? value.startIndex
        let end = value.index(range.upperBound, offsetBy: 110, limitedBy: value.endIndex) ?? value.endIndex
        return (start == value.startIndex ? "" : "…") + value[start..<end] + (end == value.endIndex ? "" : "…")
    }
}

private extension NoteFindMatch.Origin {
    var sortOrder: Int {
        switch self {
        case .written: 0
        case .corrected: 1
        case .recognized: 2
        }
    }
}
