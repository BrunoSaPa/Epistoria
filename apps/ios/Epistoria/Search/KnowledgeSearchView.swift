import EpistoriaCore
import SwiftUI

struct KnowledgeSearchView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case notes = "Notes"
        case resources = "Resources"
        case sessions = "Sessions"

        var id: Self { self }
    }

    @Bindable var model: AppModel
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var scope = Scope.all
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "Search your knowledge",
                        systemImage: "text.magnifyingglass",
                        description: Text("Titles, typed notes, transcriptions, annotations, resources, and reviewed AI artifacts are indexed only inside the encrypted database.")
                    )
                } else if isSearching {
                    ProgressView("Searching locally…")
                } else if hits.isEmpty {
                    ContentUnavailableView {
                        Label("No matches", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try fewer words, different wording, or the All scope. Search stays entirely on this iPad.")
                    } actions: {
                        if scope != .all {
                            Button("Search everything") { scope = .all }
                                .buttonStyle(.bordered)
                        }
                    }
                } else {
                    List {
                        if !exactHits.isEmpty {
                            Section("Exact matches") {
                                ForEach(exactHits) { hit in
                                    resultLink(for: hit)
                                }
                            }
                        }
                        if !relatedHits.isEmpty {
                            Section {
                                ForEach(relatedHits) { hit in
                                    resultLink(for: hit)
                                }
                            } header: {
                                Text("Related")
                            } footer: {
                                Text("Matched by meaning on this iPad. Related results never use your AI provider.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search titles and content")
            .searchScopes($scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .task(id: query) { await search() }
            .task(id: scope) { await search(skipDelay: true) }
            .epistoriaPageBackground()
            .alert("Search error", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await search(skipDelay: true) } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func search(skipDelay: Bool = false) async {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let database = model.database else {
            hits = []
            return
        }
        isSearching = true
        if !skipDelay { try? await Task.sleep(for: .milliseconds(220)) }
        guard !Task.isCancelled else { return }
        do {
            let results = try await database.search(clean, entityTypes: scopedEntityTypes)
            guard !Task.isCancelled else { return }
            hits = results
            isSearching = false
        } catch {
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }

    private var scopedEntityTypes: [EntityType]? {
        switch scope {
        case .all:
            nil
        case .notes:
            [.note, .noteBlock]
        case .resources:
            [.resource, .asset, .annotation, .transcriptCorrection, .evidence, .aiArtifact]
        case .sessions:
            [.studySession]
        }
    }

    private var exactHits: [SearchHit] {
        hits.filter { $0.matchKind == .exact }
    }

    private var relatedHits: [SearchHit] {
        hits.filter { $0.matchKind == .related }
    }

    private func resultLink(for hit: SearchHit) -> some View {
        NavigationLink {
            SearchDestination(model: model, hit: hit)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(title(for: hit), systemImage: symbol(for: hit.entity.entityType))
                        .font(.headline)
                    Spacer()
                    Text(typeLabel(hit.entity.entityType))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                if !hit.snippet.isEmpty {
                    Text(cleanSnippet(hit.snippet))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 3)
        }
        .accessibilityIdentifier("search.result.\(hit.entity.id.uuidString)")
    }

    private func title(for hit: SearchHit) -> String {
        let content = hit.entity.content
        switch hit.entity.entityType {
        case .note:
            return (try? CanonicalJSON.decode(NotePayload.self, from: content).title) ?? "Note"
        case .studySession:
            return (try? CanonicalJSON.decode(StudySessionPayload.self, from: content).title) ?? "Session"
        case .resource:
            return (try? CanonicalJSON.decode(ResourcePayload.self, from: content).title) ?? "Resource"
        case .course:
            return (try? CanonicalJSON.decode(CoursePayload.self, from: content).name) ?? "Course"
        case .institution:
            return (try? CanonicalJSON.decode(InstitutionPayload.self, from: content).name) ?? "Institution"
        case .academicTerm:
            return (try? CanonicalJSON.decode(AcademicTermPayload.self, from: content).name) ?? "Academic term"
        case .noteBlock: return "Note excerpt"
        case .annotation: return "Annotation"
        case .transcriptCorrection: return "Transcript correction"
        case .asset:
            return (try? CanonicalJSON.decode(AssetPayload.self, from: content).originalFilename) ?? "Asset"
        case .aiArtifact: return "AI artifact"
        default: return typeLabel(hit.entity.entityType)
        }
    }

    private func cleanSnippet(_ value: String) -> String {
        value.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    }

    private func symbol(for type: EntityType) -> String {
        switch type {
        case .note, .noteBlock: "doc.text"
        case .studySession: "timer"
        case .resource, .asset: "books.vertical"
        case .course, .institution, .academicTerm: "building.columns"
        case .annotation, .transcriptCorrection: "note.text"
        case .aiArtifact: "sparkles"
        default: "link"
        }
    }

    private func typeLabel(_ type: EntityType) -> String {
        type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct SearchDestination: View {
    @Bindable var model: AppModel
    let hit: SearchHit

    var body: some View {
        destination
    }

    @ViewBuilder
    private var destination: some View {
        switch hit.entity.entityType {
        case .note:
            NoteEditorView(model: model, noteId: hit.entity.id)
        case .noteBlock:
            if let noteId = hit.entity.parentId {
                NoteEditorView(
                    model: model,
                    noteId: noteId,
                    focusedBlockId: hit.entity.id,
                    highlightText: navigationSearchText(for: hit)
                )
            } else {
                SearchRecordView(hit: hit)
            }
        case .studySession:
            SessionDetailView(model: model, sessionId: hit.entity.id)
        case .resource:
            ResourceDetailView(model: model, resourceId: hit.entity.id)
        case .annotation:
            if let annotation = try? CanonicalJSON.decode(AnnotationPayload.self, from: hit.entity.content) {
                ResourceDetailView(
                    model: model,
                    resourceId: annotation.resourceId,
                    sessionId: annotation.studySessionId,
                    initialPageNumber: annotation.pageNumber,
                    focusedAnnotationId: hit.entity.id,
                    highlightText: annotation.selectedText
                )
            } else {
                SearchRecordView(hit: hit)
            }
        case .transcriptCorrection:
            if let correction = try? CanonicalJSON.decode(
                TranscriptCorrectionPayload.self,
                from: hit.entity.content
            ) {
                ResourceDetailView(
                    model: model,
                    resourceId: correction.sourceId,
                    initialSourceVersionId: correction.sourceVersionId,
                    highlightText: correction.correctedText,
                    initialMediaTimeSeconds: correction.startSeconds
                )
            } else {
                SearchRecordView(hit: hit)
            }
        case .evidence:
            if let evidence = try? CanonicalJSON.decode(EvidencePayload.self, from: hit.entity.content) {
                ResourceDetailView(
                    model: model,
                    resourceId: evidence.sourceId,
                    initialSourceVersionId: evidence.sourceVersionId,
                    initialPageNumber: evidence.locator.page,
                    highlightText: evidence.excerpt,
                    initialMediaTimeSeconds: evidence.locator.startSeconds
                )
            } else {
                SearchRecordView(hit: hit)
            }
        case .aiArtifact:
            if let artifact = try? CanonicalJSON.decode(SessionDigestArtifact.self, from: hit.entity.content) {
                SessionDetailView(model: model, sessionId: artifact.sessionId)
            } else if let chunk = try? CanonicalJSON.decode(PDFExtractionChunk.self, from: hit.entity.content) {
                let term = navigationSearchText(for: hit)
                ResourceDetailView(
                    model: model,
                    resourceId: chunk.resourceId,
                    initialPageNumber: matchingPage(in: chunk, term: term),
                    highlightText: term
                )
            } else if let manifest = try? CanonicalJSON.decode(PDFExtractionManifest.self, from: hit.entity.content) {
                ResourceDetailView(model: model, resourceId: manifest.resourceId)
            } else if let manifest = try? CanonicalJSON.decode(
                MediaTranscriptionManifest.self,
                from: hit.entity.content
            ) {
                ResourceDetailView(model: model, resourceId: manifest.sourceId)
            } else {
                SearchRecordView(hit: hit)
            }
        default:
            SearchRecordView(hit: hit)
        }
    }

    private func matchingPage(in chunk: PDFExtractionChunk, term: String?) -> Int? {
        guard let term, !term.isEmpty else { return chunk.pages.first?.pageNumber }
        return chunk.pages.first {
            $0.text.localizedCaseInsensitiveContains(term)
        }?.pageNumber ?? chunk.pages.first?.pageNumber
    }
}

private struct SearchRecordView: View {
    let hit: SearchHit

    var body: some View {
        List {
            Section("Matched content") {
                Text(hit.snippet.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))
            }
            Section("Record") {
                LabeledContent("Type", value: hit.entity.entityType.rawValue)
                LabeledContent("Updated", value: hit.entity.clientModifiedAt.formatted())
                LabeledContent("Sync state", value: hit.entity.syncState.rawValue.capitalized)
            }
        }
        .navigationTitle("Search result")
    }
}

private func matchedSearchText(in snippet: String) -> String? {
    guard let open = snippet.firstIndex(of: "[") else { return nil }
    let remainder = snippet[snippet.index(after: open)...]
    guard let close = remainder.firstIndex(of: "]") else { return nil }
    let match = remainder[..<close].trimmingCharacters(in: .whitespacesAndNewlines)
    return match.count >= 2 ? match : nil
}

private func navigationSearchText(for hit: SearchHit) -> String? {
    if hit.matchKind == .exact {
        return matchedSearchText(in: hit.snippet)
    }
    let text = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count >= 2 else { return nil }
    return String(text.prefix(120))
}
