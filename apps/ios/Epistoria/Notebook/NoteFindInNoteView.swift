import EpistoriaCore
import SwiftUI

struct NoteFindMatch: Identifiable {
    enum Origin {
        case written
        case recognized
        case corrected

        var label: String {
            switch self {
            case .written: "Written text"
            case .recognized: "Recognized from handwriting · Unreviewed"
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
    let onOpen: (NoteFindMatch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
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
                                    Text(snippet(match.text))
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
            .searchable(text: $query, prompt: "Find text or handwriting")
            .navigationTitle("Find in Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var matches: [NoteFindMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var values: [NoteFindMatch] = []
        for block in blocks where !block.payload.tombstone {
            let text = block.payload.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.localizedCaseInsensitiveContains(needle) {
                values.append(NoteFindMatch(
                    id: "block:\(block.id.uuidString)",
                    blockId: block.id,
                    pageIndex: pageIndex(for: block.payload),
                    text: text,
                    origin: .written,
                    rectangles: []
                ))
            }
        }
        for artifact in artifacts
        where artifact.payload.state == .current && artifact.payload.reviewState != .rejected {
            guard let block = blocks.first(where: { $0.id == artifact.payload.targetId && !$0.payload.tombstone })
            else { continue }
            let text = artifact.payload.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.localizedCaseInsensitiveContains(needle) else { continue }
            values.append(NoteFindMatch(
                id: "ocr:\(artifact.id.uuidString)",
                blockId: block.id,
                pageIndex: pageIndex(for: block.payload),
                text: text,
                origin: artifact.payload.reviewState == .edited ? .corrected : .recognized,
                rectangles: artifact.payload.response.regions.flatMap(\.rectangles)
            ))
        }
        return values.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return $0.origin.sortOrder < $1.origin.sortOrder
        }
    }

    private func pageIndex(for block: NoteBlockPayload) -> Int {
        if let pageId = block.canvasPageId,
           let index = pages.firstIndex(where: { $0.id == pageId })
        {
            return index
        }
        return max(block.canvasPageIndex ?? 0, 0)
    }

    private func pageColor(at index: Int) -> Color {
        guard pages.indices.contains(index) else { return .white }
        return pages[index].payload.configuration.paperColor.swiftUIColor
    }

    private func snippet(_ text: String) -> String {
        let value = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
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
