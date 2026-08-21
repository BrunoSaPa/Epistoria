import EpistoriaCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    private enum LibrarySection: String, CaseIterable, Identifiable {
        case inbox = "Inbox"
        case all = "All Sources"
        case recent = "Recent"
        case archived = "Archived"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    @State private var resources: [IdentifiedPayload<SourcePayload>] = []
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var section = LibrarySection.inbox
    @State private var selectedType: ResourceKind?
    @State private var selectedTopicId: UUID?
    @State private var isImporting = false
    @State private var importProgress: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if visibleResources.isEmpty {
                    ContentUnavailableView {
                        Label("Your private library", systemImage: "books.vertical")
                    } description: {
                        Text(emptyDescription)
                    } actions: {
                        Button("Import your first Source") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                            .tint(EpistoriaDesign.ink)
                    }
                } else {
                    List(visibleResources, id: \.id) { resource in
                        NavigationLink {
                            ResourceDetailView(model: model, resourceId: resource.id)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: resource.payload.sourceType == .pdf ? "doc.richtext" : "doc.text")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(resource.payload.title).font(.headline)
                                    Text("\(resource.payload.sourceType.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) · imported \(resource.payload.importedAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("library.resource.\(resource.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(resource.payload.archivedAt == nil ? "Archive" : "Restore", systemImage: resource.payload.archivedAt == nil ? "archivebox" : "arrow.uturn.backward") {
                                Task { await setSourceArchived(resource, archived: resource.payload.archivedAt == nil) }
                            }
                            .tint(.gray)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .epistoriaPageBackground()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Library section", selection: $section) {
                        ForEach(LibrarySection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 390)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Any type") { selectedType = nil }
                        ForEach(ResourceKind.allCases, id: \.self) { kind in
                            Button(kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) { selectedType = kind }
                        }
                        Divider()
                        Button("Any Topic") { selectedTopicId = nil }
                        ForEach(topics, id: \.id) { topic in Button(topic.payload.name) { selectedTopicId = topic.id } }
                    } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                    Button { isImporting = true } label: {
                        Label("Import Source", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let importProgress {
                    HStack {
                        ProgressView()
                        Text(importProgress)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.pdf, .image, .plainText, .html, UTType(filenameExtension: "md") ?? .plainText],
                allowsMultipleSelection: true
            ) { result in
                Task { await importFiles(result) }
            }
            .task { await load() }
            .refreshable { await load() }
            .alert("Library error", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await load() } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedResources = store.list(SourcePayload.self)
            async let loadedTopics = store.topics()
            let result = try await (loadedResources, loadedTopics)
            resources = result.0.sorted { $0.payload.importedAt > $1.payload.importedAt }
            topics = result.1.filter { !$0.payload.archived }
        }
        catch { errorMessage = error.localizedDescription }
    }

    private var visibleResources: [IdentifiedPayload<SourcePayload>] {
        resources.filter { resource in
            let sectionMatches = switch section {
            case .inbox: resource.payload.archivedAt == nil && resource.payload.primaryTopicId == nil
            case .all, .recent: resource.payload.archivedAt == nil
            case .archived: resource.payload.archivedAt != nil
            }
            let typeMatches = selectedType.map { resource.payload.sourceType == $0 } ?? true
            let topicMatches = selectedTopicId.map {
                resource.payload.primaryTopicId == $0 || resource.payload.relatedTopicIds.contains($0)
            } ?? true
            return sectionMatches && typeMatches && topicMatches
        }
        .prefix(section == .recent ? 20 : Int.max)
        .map { $0 }
    }

    private var emptyDescription: String {
        if !resources.isEmpty && section == .inbox {
            return "Source Inbox is clear. Unassigned imports appear here until you choose a Topic."
        }
        return "Import PDFs, images, text, Markdown, or HTML. Epistoria encrypts the original locally before it can sync."
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard let assetManager = model.assetManager else { return }
        do {
            let urls = try result.get()
            for (index, url) in urls.enumerated() {
                importProgress = "Encrypting \(index + 1) of \(urls.count): \(url.lastPathComponent)"
                _ = try await assetManager.importPhaseOneSource(from: url)
            }
            model.noteLocalMutation()
            importProgress = nil
            await load()
        } catch {
            importProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func setSourceArchived(_ source: IdentifiedPayload<SourcePayload>, archived: Bool) async {
        guard let store = model.store else { return }
        do {
            try await store.updateSource(
                id: source.id,
                title: source.payload.title,
                primaryTopicId: source.payload.primaryTopicId,
                relatedTopicIds: source.payload.relatedTopicIds,
                listIds: source.payload.listIds,
                archived: archived
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ResourceDetailView: View {
    @Bindable var model: AppModel
    let resourceId: UUID
    var sessionId: UUID?
    var initialPageNumber: Int?
    var focusedAnnotationId: UUID?
    var highlightText: String?

    @State private var resource: IdentifiedPayload<ResourcePayload>?
    @State private var source: IdentifiedPayload<SourcePayload>?
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var lists: [IdentifiedPayload<CollectionPayload>] = []
    @State private var versions: [IdentifiedPayload<SourceVersionPayload>] = []
    @State private var isOrganizing = false
    @State private var isRefreshingSource = false
    @State private var pdfData: Data?
    @State private var pageNumber = 1
    @State private var pageCount = 0
    @State private var annotations: [IdentifiedPayload<AnnotationPayload>] = []
    @State private var extraction: IdentifiedPayload<PDFExtractionManifest>?
    @State private var extractionJob: AIJobSummary?
    @State private var annotationKind = AnnotationKind.comment
    @State private var comment = ""
    @State private var isLoading = true
    @State private var isInspectorPresented = true
    @State private var editingAnnotation: IdentifiedPayload<AnnotationPayload>?
    @State private var pendingDeletion: IdentifiedPayload<AnnotationPayload>?
    @State private var recentlyDeleted: IdentifiedPayload<AnnotationPayload>?
    @State private var hasRecordedSessionOpen = false
    @State private var errorMessage: String?
    @FocusState private var annotationEditorFocused: Bool

    init(
        model: AppModel,
        resourceId: UUID,
        sessionId: UUID? = nil,
        initialPageNumber: Int? = nil,
        focusedAnnotationId: UUID? = nil,
        highlightText: String? = nil
    ) {
        self.model = model
        self.resourceId = resourceId
        self.sessionId = sessionId
        self.initialPageNumber = initialPageNumber
        self.focusedAnnotationId = focusedAnnotationId
        self.highlightText = highlightText
        _pageNumber = State(initialValue: max(initialPageNumber ?? 1, 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Decrypting locally…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pdfData, resource?.payload.resourceType == .pdf {
                PDFDocumentView(data: pdfData, pageNumber: $pageNumber, pageCount: $pageCount, highlightText: highlightText)
            } else if let pdfData, resource?.payload.resourceType == .image,
                      let image = UIImage(data: pdfData) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().padding(24)
                }
            } else if let pdfData,
                      let text = String(data: pdfData, encoding: .utf8) {
                ScrollView {
                    Text(text)
                        .font(resource?.payload.resourceType == .markdown ? .body.monospaced() : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: EpistoriaDesign.Layout.readingWidth, alignment: .leading)
                        .padding(EpistoriaDesign.Spacing.page)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                ContentUnavailableView {
                    Label("File unavailable", systemImage: "doc.questionmark")
                } description: {
                    Text("The encrypted original is not present on this device yet.")
                } actions: {
                    Button("Check again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .epistoriaPageBackground()
        .navigationTitle(resource?.payload.title ?? "Resource")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { isOrganizing = true } label: {
                    Label("Edit Source", systemImage: "slider.horizontal.3")
                }
                Button { isRefreshingSource = true } label: {
                    Label("Refresh Source", systemImage: "arrow.clockwise")
                }
                if pageCount > 0 {
                    Button {
                        pageNumber = max(1, pageNumber - 1)
                    } label: {
                        Label("Previous page", systemImage: "chevron.left")
                    }
                    .disabled(pageNumber <= 1)

                    Text("\(pageNumber) / \(pageCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Page \(pageNumber) of \(pageCount)")

                    Button {
                        pageNumber = min(pageCount, pageNumber + 1)
                    } label: {
                        Label("Next page", systemImage: "chevron.right")
                    }
                    .disabled(pageNumber >= pageCount)
                }
                if resource?.payload.resourceType == .pdf { Button {
                    comment = ""
                    isInspectorPresented = true
                    annotationEditorFocused = true
                } label: {
                    Label("Annotate page", systemImage: "note.text.badge.plus")
                }
                .accessibilityIdentifier("resource.annotate")

                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(
                        isInspectorPresented ? "Hide annotations" : "Show annotations",
                        systemImage: "sidebar.trailing"
                    )
                }
                .accessibilityIdentifier("resource.toggle-inspector")
                }
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            annotationInspector
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        .task { await load() }
        .fileImporter(
            isPresented: $isRefreshingSource,
            allowedContentTypes: [.pdf, .image, .plainText, .html]
        ) { result in
            Task { await refreshSource(result) }
        }
        .sheet(isPresented: $isOrganizing) {
            SourceOrganizationView(
                model: model,
                source: source,
                topics: topics,
                lists: lists
            ) {
                isOrganizing = false
                Task { await load() }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { editingAnnotation != nil },
                set: { if !$0 { editingAnnotation = nil } }
            )
        ) {
            if let editingAnnotation {
                EditAnnotationView(model: model, annotation: editingAnnotation) {
                    self.editingAnnotation = nil
                    Task { await load() }
                }
            }
        }
        .confirmationDialog(
            "Delete this annotation?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete annotation", role: .destructive) {
                guard let pendingDeletion else { return }
                Task { await deleteAnnotation(pendingDeletion) }
                self.pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The PDF itself is never changed. You can undo while this resource remains open.")
        }
        .safeAreaInset(edge: .bottom) {
            if recentlyDeleted != nil {
                HStack(spacing: 14) {
                    Label("Annotation deleted", systemImage: "trash")
                    Spacer()
                    Button("Undo") { Task { await undoAnnotationDelete() } }
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8, y: 3)
                .padding()
            }
        }
        .alert("Resource error", isPresented: .constant(errorMessage != nil)) {
            Button("Try again") { Task { await load() } }
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var annotationInspector: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                Section {
                    Label("Original PDF preserved", systemImage: "lock.doc")
                        .foregroundStyle(.secondary)
                    Text("Annotations are separate encrypted records, so importing never modifies the source file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Searchable text") {
                    if let extraction {
                        Label("\(extraction.payload.pageCount) pages indexed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(EpistoriaDesign.positive)
                        LabeledContent(
                            "Characters",
                            value: extraction.payload.characterCount.formatted()
                        )
                        if !extraction.payload.pagesNeedingOcr.isEmpty {
                            Text("OCR still needed on pages: \(extraction.payload.pagesNeedingOcr.map(String.init).joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(EpistoriaDesign.attention)
                        }
                    } else if let extractionJob {
                        Label("Mac job \(extractionJob.status.lowercased())", systemImage: "desktopcomputer")
                        Text("Run the trusted worker, then sync this iPad to index the result.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Extract text on trusted Mac", systemImage: "text.viewfinder") {
                            Task { await queueExtraction() }
                        }
                        .disabled(model.aiJobs == nil)
                        Text("This is local processing and does not call an AI provider. The decrypted PDF exists only in Mac memory while text is extracted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Versions") {
                    ForEach(versions, id: \.id) { version in
                        HStack {
                            Text("Version \(version.payload.versionNumber)")
                            Spacer()
                            if version.id == source?.payload.currentVersionId {
                                Text("Current").font(.caption.bold())
                            }
                        }
                    }
                    Text("Refresh creates a new immutable version. Existing citations and study records keep their original version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Add to page \(pageNumber)") {
                    Picker("Kind", selection: $annotationKind) {
                        ForEach(AnnotationKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue.capitalized).tag(kind)
                        }
                    }
                    TextEditor(text: $comment)
                        .frame(minHeight: 90)
                        .focused($annotationEditorFocused)
                        .accessibilityLabel("Annotation text")
                        .accessibilityIdentifier("resource.annotation-text")
                    Button("Save annotation") { Task { await saveAnnotation() } }
                        .buttonStyle(.borderedProminent)
                        .tint(EpistoriaDesign.ink)
                        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("resource.save-annotation")
                    Text("Saved annotations also become reusable Evidence bound to this exact Source Version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Annotations") {
                    if annotations.isEmpty {
                        Text("No annotations yet").foregroundStyle(.secondary)
                    }
                    ForEach(annotations, id: \.id) { annotation in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                EpistoriaStatusPill(
                                    title: annotation.payload.annotationType.rawValue.capitalized,
                                    symbol: annotationSymbol(annotation.payload.annotationType)
                                )
                                Spacer()
                                if let page = annotation.payload.pageNumber {
                                    Button("Page \(page)") {
                                        pageNumber = page
                                    }
                                        .font(.caption)
                                }
                            }
                            Text(annotation.payload.comment)
                                .textSelection(.enabled)
                            Text(annotation.payload.updatedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(
                            annotation.id == focusedAnnotationId
                                ? Color.primary.opacity(0.08)
                                : Color.clear
                        )
                        .id(annotation.id)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("resource.annotation.\(annotation.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDeletion = annotation
                            }
                            Button("Edit", systemImage: "pencil") {
                                editingAnnotation = annotation
                            }
                            .tint(EpistoriaDesign.accent)
                        }
                        .contextMenu {
                            Button("Edit annotation", systemImage: "pencil") {
                                editingAnnotation = annotation
                            }
                            Button("Delete annotation…", systemImage: "trash", role: .destructive) {
                                pendingDeletion = annotation
                            }
                        }
                    }
                }
                }
                .navigationTitle("Notes")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isInspectorPresented = false }
                    }
                }
                .task(id: focusedAnnotationId) {
                    guard let focusedAnnotationId else { return }
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(focusedAnnotationId, anchor: .center)
                    }
                }
            }
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            let loaded = try await store.payload(ResourcePayload.self, id: resourceId)
            async let loadedSource = store.payload(SourcePayload.self, id: resourceId)
            async let loadedTopics = store.topics()
            async let loadedLists = store.lists()
            resource = loaded
            source = try await loadedSource
            topics = try await loadedTopics.filter { !$0.payload.archived }
            lists = try await loadedLists.filter { $0.payload.archivedAt == nil }
            versions = try await store.list(SourceVersionPayload.self, parentId: resourceId)
                .sorted { $0.payload.versionNumber > $1.payload.versionNumber }
            annotations = try await store.list(AnnotationPayload.self)
                .filter { $0.payload.resourceId == resourceId }
                .sorted {
                    ($0.payload.pageNumber ?? 0, $0.payload.updatedAt)
                        < ($1.payload.pageNumber ?? 0, $1.payload.updatedAt)
                }
            if let focusedAnnotationId,
               let focused = annotations.first(where: { $0.id == focusedAnnotationId }),
               let page = focused.payload.pageNumber
            {
                pageNumber = page
                isInspectorPresented = true
            } else if let initialPageNumber {
                pageNumber = max(initialPageNumber, 1)
            }
            extraction = try await model.aiJobs?.latestPDFExtraction(resourceId: resourceId)
            if let assetId = loaded.payload.originalAssetId, let assetManager = model.assetManager {
                pdfData = try await assetManager.decryptedData(assetId: assetId)
            }
            if let sessionId, !hasRecordedSessionOpen,
               let session = try? await store.payload(StudySessionPayload.self, id: sessionId),
               session.payload.state == .active || session.payload.state == .paused
            {
                _ = try await store.recordSessionActivity(
                    sessionId: sessionId,
                    itemId: resourceId,
                    kind: .sourceOpened
                )
                hasRecordedSessionOpen = true
                model.noteLocalMutation()
            }
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshSource(_ result: Result<URL, Error>) async {
        guard let manager = model.assetManager else { return }
        do {
            _ = try await manager.refreshPhaseOneSource(id: resourceId, from: result.get())
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveAnnotation() async {
        guard let store = model.store else { return }
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            var payload = AnnotationPayload(
                resourceId: resourceId,
                annotationType: annotationKind,
                pageNumber: pageNumber,
                comment: clean
            )
            payload.studySessionId = sessionId
            if let sourceVersionId = source?.payload.currentVersionId {
                _ = try await store.createAnnotationEvidence(
                    annotation: payload,
                    sourceVersionId: sourceVersionId
                )
            } else {
                _ = try await store.save(
                    payload: payload,
                    parentId: resourceId,
                    relationIds: [resourceId, sessionId].compactMap(\.self)
                )
            }
            comment = ""
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func queueExtraction() async {
        guard let coordinator = model.aiJobs else {
            errorMessage = "Connect the private server and pair your trusted Mac first."
            return
        }
        await model.synchronize()
        if let syncError = model.syncError {
            errorMessage = syncError
            return
        }
        do { extractionJob = try await coordinator.submitPDFExtraction(resourceId: resourceId) }
        catch { errorMessage = error.localizedDescription }
    }

    private func deleteAnnotation(_ annotation: IdentifiedPayload<AnnotationPayload>) async {
        guard let database = model.database else { return }
        do {
            try await database.deleteLocal(id: annotation.id)
            recentlyDeleted = annotation
            model.noteLocalMutation()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undoAnnotationDelete() async {
        guard let store = model.store, let annotation = recentlyDeleted else { return }
        do {
            _ = try await store.save(
                id: annotation.id,
                payload: annotation.payload,
                parentId: resourceId,
                relationIds: [
                    Optional(resourceId),
                    annotation.payload.studySessionId,
                    annotation.payload.noteId,
                ].compactMap(\.self)
            )
            recentlyDeleted = nil
            model.noteLocalMutation()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func annotationSymbol(_ kind: AnnotationKind) -> String {
        switch kind {
        case .highlight: "highlighter"
        case .comment: "text.bubble"
        case .question: "questionmark.circle"
        case .idea: "lightbulb"
        case .important: "exclamationmark.circle"
        case .disagreement: "hand.thumbsdown"
        case .summary: "text.alignleft"
        case .bookmark: "bookmark"
        case .drawing: "pencil.tip"
        }
    }
}

private struct SourceOrganizationView: View {
    @Bindable var model: AppModel
    let source: IdentifiedPayload<SourcePayload>?
    let topics: [IdentifiedPayload<TopicPayload>]
    let lists: [IdentifiedPayload<CollectionPayload>]
    let onSaved: () -> Void
    @State private var title: String
    @State private var primaryTopicId: UUID?
    @State private var relatedTopicIds: Set<UUID>
    @State private var listIds: Set<UUID>
    @State private var archived: Bool
    @State private var errorMessage: String?

    init(
        model: AppModel,
        source: IdentifiedPayload<SourcePayload>?,
        topics: [IdentifiedPayload<TopicPayload>],
        lists: [IdentifiedPayload<CollectionPayload>],
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.source = source
        self.topics = topics
        self.lists = lists
        self.onSaved = onSaved
        _title = State(initialValue: source?.payload.title ?? "")
        _primaryTopicId = State(initialValue: source?.payload.primaryTopicId)
        _relatedTopicIds = State(initialValue: Set(source?.payload.relatedTopicIds ?? []))
        _listIds = State(initialValue: Set(source?.payload.listIds ?? []))
        _archived = State(initialValue: source?.payload.archivedAt != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    TextField("Title", text: $title)
                    Toggle("Archived", isOn: $archived)
                }
                Section("Primary Topic") {
                    Picker("Primary Topic", selection: $primaryTopicId) {
                        Text("Source Inbox").tag(UUID?.none)
                        ForEach(topics, id: \.id) { Text($0.payload.name).tag(Optional($0.id)) }
                    }
                    Text("A Source can remain in Inbox. Assigning it later does not change its immutable versions or citations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Related Topics") {
                    ForEach(topics.filter { $0.id != primaryTopicId }, id: \.id) { topic in
                        Toggle(topic.payload.name, isOn: membership(topic.id, in: $relatedTopicIds))
                    }
                    if topics.filter({ $0.id != primaryTopicId }).isEmpty {
                        Text("No other Topics").foregroundStyle(.secondary)
                    }
                }
                Section("Lists") {
                    ForEach(lists, id: \.id) { list in
                        Toggle(list.payload.name, isOn: membership(list.id, in: $listIds))
                    }
                    if lists.isEmpty { Text("No active Lists").foregroundStyle(.secondary) }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Edit Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onSaved() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        guard let store = model.store, let source else { return }
        do {
            try await store.updateSource(
                id: source.id,
                title: title,
                primaryTopicId: primaryTopicId,
                relatedTopicIds: Array(relatedTopicIds),
                listIds: Array(listIds),
                archived: archived
            )
            model.noteLocalMutation()
            onSaved()
        } catch { errorMessage = error.localizedDescription }
    }

    private func membership(_ id: UUID, in values: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(
            get: { values.wrappedValue.contains(id) },
            set: { selected in
                if selected { values.wrappedValue.insert(id) }
                else { values.wrappedValue.remove(id) }
            }
        )
    }
}

private struct EditAnnotationView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let annotation: IdentifiedPayload<AnnotationPayload>
    let onSaved: () -> Void

    @State private var kind: AnnotationKind
    @State private var pageNumber: Int
    @State private var comment: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        model: AppModel,
        annotation: IdentifiedPayload<AnnotationPayload>,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.annotation = annotation
        self.onSaved = onSaved
        _kind = State(initialValue: annotation.payload.annotationType)
        _pageNumber = State(initialValue: max(annotation.payload.pageNumber ?? 1, 1))
        _comment = State(initialValue: annotation.payload.comment)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(AnnotationKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue.capitalized).tag(kind)
                    }
                }
                Stepper("Page \(pageNumber)", value: $pageNumber, in: 1...100_000)
                Section("Annotation") {
                    TextEditor(text: $comment)
                        .frame(minHeight: 150)
                        .accessibilityIdentifier("annotation-edit.comment")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit annotation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("annotation-edit.save")
                }
            }
        }
    }

    private func save() async {
        guard let store = model.store else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            var payload = annotation.payload
            payload.annotationType = kind
            payload.pageNumber = pageNumber
            payload.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            payload.updatedAt = .now
            _ = try await store.save(
                id: annotation.id,
                payload: payload,
                parentId: payload.resourceId,
                relationIds: [
                    Optional(payload.resourceId),
                    payload.studySessionId,
                    payload.noteId,
                ].compactMap(\.self)
            )
            model.noteLocalMutation()
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let data: Data
    @Binding var pageNumber: Int
    @Binding var pageCount: Int
    let highlightText: String?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        context.coordinator.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        DispatchQueue.main.async {
            context.coordinator.updatePage()
            context.coordinator.applyHighlightIfNeeded(highlightText)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        // `data` is immutable for the lifetime of this detail view. Re-serializing the
        // PDFDocument here would copy the entire file on routine page/highlight updates.
        context.coordinator.applyHighlightIfNeeded(highlightText)
        guard let document = view.document,
              pageNumber > 0,
              pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1),
              view.currentPage !== page
        else { return }
        view.go(to: page)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: view)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFDocumentView
        weak var pdfView: PDFView?
        private var lastHighlight: String?

        init(parent: PDFDocumentView) { self.parent = parent }

        @objc func pageChanged() { updatePage() }

        func updatePage() {
            guard let view = pdfView, let document = view.document else { return }
            parent.pageCount = document.pageCount
            if let current = view.currentPage {
                parent.pageNumber = document.index(for: current) + 1
            }
        }

        func applyHighlightIfNeeded(_ value: String?) {
            let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean != lastHighlight else { return }
            lastHighlight = clean
            guard let clean, clean.count >= 2, let view = pdfView, let document = view.document else {
                viewClearHighlights()
                return
            }
            let selections = document.findString(clean, withOptions: .caseInsensitive)
            let preferredPageIndex = max(parent.pageNumber - 1, 0)
            let preferred = selections.first { selection in
                guard let page = selection.pages.first else { return false }
                return document.index(for: page) == preferredPageIndex
            } ?? selections.first
            guard let preferred else { return }
            preferred.color = UIColor.systemYellow.withAlphaComponent(0.45)
            view.highlightedSelections = [preferred]
            view.go(to: preferred)
            updatePage()
            UIAccessibility.post(notification: .announcement, argument: "Matched PDF text highlighted")
        }

        private func viewClearHighlights() {
            pdfView?.highlightedSelections = nil
        }
    }

}
