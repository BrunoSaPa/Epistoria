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
                        Text("Try fewer words, another spelling, or the All scope. Search stays entirely inside your encrypted database.")
                    } actions: {
                        if scope != .all {
                            Button("Search everything") { scope = .all }
                                .buttonStyle(.bordered)
                        }
                    }
                } else {
                    List(hits) { hit in
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
            hits = try await database.search(clean).filter(isInScope)
            isSearching = false
        } catch {
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }

    private func isInScope(_ hit: SearchHit) -> Bool {
        switch scope {
        case .all:
            true
        case .notes:
            [.note, .noteBlock].contains(hit.entity.entityType)
        case .resources:
            [.resource, .asset, .annotation, .aiArtifact].contains(hit.entity.entityType)
        case .sessions:
            hit.entity.entityType == .studySession
        }
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
        case .annotation: "note.text"
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
                    highlightText: matchedSearchText(in: hit.snippet)
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
        case .aiArtifact:
            if let artifact = try? CanonicalJSON.decode(SessionDigestArtifact.self, from: hit.entity.content) {
                SessionDetailView(model: model, sessionId: artifact.sessionId)
            } else if let chunk = try? CanonicalJSON.decode(PDFExtractionChunk.self, from: hit.entity.content) {
                let term = matchedSearchText(in: hit.snippet)
                ResourceDetailView(
                    model: model,
                    resourceId: chunk.resourceId,
                    initialPageNumber: matchingPage(in: chunk, term: term),
                    highlightText: term
                )
            } else if let manifest = try? CanonicalJSON.decode(PDFExtractionManifest.self, from: hit.entity.content) {
                ResourceDetailView(model: model, resourceId: manifest.resourceId)
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
