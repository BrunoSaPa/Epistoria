import AVFAudio
import AVFoundation
import AVKit
import EpistoriaCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

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
    @State private var sourceCursor: EntityPageCursor?
    @State private var isLoadingMore = false
    @State private var section = LibrarySection.inbox
    @State private var selectedType: SourceKind?
    @State private var selectedTopicId: UUID?
    @State private var isImporting = false
    @State private var isCapturingWebPage = false
    @State private var webAddress = ""
    @State private var webTopicId: UUID?
    @State private var isCapturingGoogleFile = false
    @State private var googleAddress = ""
    @State private var googleTopicId: UUID?
    @State private var isAddingYouTubeVideo = false
    @State private var youtubeAddress = ""
    @State private var youtubeTitle = ""
    @State private var youtubeTopicId: UUID?
    @State private var importProgress: String?
    @State private var pendingTrashSource: IdentifiedPayload<SourcePayload>?
    @State private var isConfirmingFailedCaptureDiscard = false
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
                        VStack(spacing: 10) {
                            HStack {
                                Button("Import a file") { isImporting = true }
                                    .buttonStyle(.borderedProminent)
                                    .tint(EpistoriaDesign.ink)
                                Button("Capture a webpage") { isCapturingWebPage = true }
                                    .buttonStyle(.bordered)
                            }
                            HStack {
                                Button("Add Google file") { isCapturingGoogleFile = true }
                                    .buttonStyle(.bordered)
                                Button("Add YouTube video") { isAddingYouTubeVideo = true }
                                    .buttonStyle(.bordered)
                            }
                            if sourceCursor != nil {
                                loadMoreButton
                            }
                        }
                    }
                } else {
                    List {
                        ForEach(visibleResources, id: \.id) { resource in
                            NavigationLink {
                            SourceDetailView(model: model, sourceId: resource.id)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: resource.payload.sourceType.epistoriaSymbol)
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
                        .accessibilityIdentifier("library.source.\(resource.id.uuidString)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Trash", systemImage: "trash", role: .destructive) {
                                    pendingTrashSource = resource
                                }
                                Button(resource.payload.archivedAt == nil ? "Archive" : "Restore", systemImage: resource.payload.archivedAt == nil ? "archivebox" : "arrow.uturn.backward") {
                                    Task { await setSourceArchived(resource, archived: resource.payload.archivedAt == nil) }
                                }
                                .tint(.gray)
                            }
                        }
                        if sourceCursor != nil { loadMoreButton }
                    }
                }
            }
            .navigationTitle("Library")
            .epistoriaPageBackground()
            .safeAreaInset(edge: .top) {
                sharedCaptureStatus
            }
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
                        ForEach(SourceKind.allCases, id: \.self) { kind in
                            Button(kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) { selectedType = kind }
                        }
                        Divider()
                        Button("Any Topic") { selectedTopicId = nil }
                        ForEach(topics, id: \.id) { topic in Button(topic.payload.name) { selectedTopicId = topic.id } }
                    } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                    Menu {
                        Button("Import files", systemImage: "square.and.arrow.down") {
                            isImporting = true
                        }
                        Button("Capture webpage", systemImage: "globe") {
                            isCapturingWebPage = true
                        }
                        Button("Google Docs, Slides, or Sheets", systemImage: "doc.badge.arrow.up") {
                            isCapturingGoogleFile = true
                        }
                        Button("YouTube video", systemImage: "play.rectangle") {
                            isAddingYouTubeVideo = true
                        }
                    } label: {
                        Label("Add Source", systemImage: "plus")
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
                allowedContentTypes: EpistoriaSourceImportTypes.supported,
                allowsMultipleSelection: true
            ) { result in
                Task { await importFiles(result) }
            }
            .sheet(isPresented: $isCapturingWebPage) {
                WebSnapshotCaptureSheet(
                    address: $webAddress,
                    topicId: $webTopicId,
                    topics: topics
                ) {
                    Task { await captureWebPage() }
                }
            }
            .sheet(isPresented: $isCapturingGoogleFile) {
                GoogleWorkspaceCaptureSheet(
                    address: $googleAddress,
                    topicId: $googleTopicId,
                    topics: topics
                ) {
                    Task { await captureGoogleFile() }
                }
            }
            .sheet(isPresented: $isAddingYouTubeVideo) {
                YouTubeCaptureSheet(
                    address: $youtubeAddress,
                    title: $youtubeTitle,
                    topicId: $youtubeTopicId,
                    topics: topics
                ) {
                    Task { await addYouTubeVideo() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .onChange(of: model.sharedCaptureImportRevision) {
                Task { await load() }
            }
            .alert("Library error", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await load() } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .confirmationDialog(
                "Move this Source to Trash?",
                isPresented: Binding(
                    get: { pendingTrashSource != nil },
                    set: { if !$0 { pendingTrashSource = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    guard let source = pendingTrashSource else { return }
                    Task { await moveSourceToTrash(source) }
                    pendingTrashSource = nil
                }
                Button("Cancel", role: .cancel) { pendingTrashSource = nil }
            } message: {
                Text("The Source stays encrypted. Epistoria checks protected references before permanent deletion.")
            }
            .confirmationDialog(
                "Discard failed captures?",
                isPresented: $isConfirmingFailedCaptureDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard encrypted captures", role: .destructive) {
                    model.discardFailedSharedCaptures()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes only the encrypted Share extension packages that could not be imported. Existing Sources are unchanged.")
            }
        }
    }

    @ViewBuilder
    private var sharedCaptureStatus: some View {
        if let failure = model.sharedCaptureFailureMessage,
           model.failedSharedCaptureCount > 0 {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(failure)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry") {
                    Task { await model.retryFailedSharedCaptures() }
                }
                .buttonStyle(.bordered)
                Button("Discard", role: .destructive) {
                    isConfirmingFailedCaptureDiscard = true
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.regularMaterial)
        } else if let message = model.sharedCaptureImportMessage {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") { model.sharedCaptureImportMessage = nil }
                    .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedWorkspace = store.workspaceSnapshot(
                limits: WorkspaceReadLimits(notes: 1, lists: 1, sources: 50, topics: 100, sessions: 1)
            )
            let workspace = try await loadedWorkspace
            sourceCursor = workspace.sources.nextCursor
            resources = workspace.sources.items
                .sorted { $0.payload.importedAt > $1.payload.importedAt }
            topics = workspace.topics.items.filter { !$0.payload.archived }
        }
        catch { errorMessage = error.localizedDescription }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await loadMore() }
        } label: {
            HStack {
                Spacer()
                if isLoadingMore { ProgressView() }
                Text(isLoadingMore ? "Loading…" : "Load more")
                Spacer()
            }
        }
        .disabled(isLoadingMore)
    }

    private func loadMore() async {
        guard let store = model.store, let sourceCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await store.listPage(SourcePayload.self, after: sourceCursor)
            self.sourceCursor = page.nextCursor
            resources = (resources + page.items)
                .sorted { $0.payload.importedAt > $1.payload.importedAt }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveSourceToTrash(_ source: IdentifiedPayload<SourcePayload>) async {
        guard let store = model.store else { return }
        do {
            let dependencies = try await store.list(EvidencePayload.self)
                .filter { $0.payload.sourceId == source.id }
                .map(\.id)
            _ = try await store.moveToTrash(
                targetId: source.id,
                targetType: .source,
                displayName: source.payload.title,
                dependencyIds: dependencies
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
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
        return "Import local files, webpages, shared Google files, or YouTube references. Local originals are encrypted before they can sync."
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard let assetManager = model.assetManager else { return }
        do {
            let urls = try result.get()
            for (index, url) in urls.enumerated() {
                importProgress = "Encrypting \(index + 1) of \(urls.count): \(url.lastPathComponent)"
                _ = try await assetManager.importSource(from: url)
            }
            model.noteLocalMutation()
            importProgress = nil
            await load()
        } catch {
            importProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func captureWebPage() async {
        guard let assetManager = model.assetManager else { return }
        let cleanAddress = webAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanAddress) else {
            errorMessage = WebSnapshotCaptureError.invalidURL.localizedDescription
            return
        }
        isCapturingWebPage = false
        importProgress = "Capturing webpage…"
        do {
            _ = try await assetManager.importWebSnapshot(from: url, topicId: webTopicId)
            webAddress = ""
            webTopicId = nil
            model.noteLocalMutation()
            importProgress = nil
            await load()
        } catch {
            importProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func captureGoogleFile() async {
        guard let assetManager = model.assetManager else { return }
        let cleanAddress = googleAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanAddress) else {
            errorMessage = GoogleWorkspaceCaptureError.invalidURL.localizedDescription
            return
        }
        isCapturingGoogleFile = false
        importProgress = "Capturing Google file…"
        do {
            _ = try await assetManager.importGoogleWorkspaceSnapshot(
                from: url,
                topicId: googleTopicId
            )
            googleAddress = ""
            googleTopicId = nil
            model.noteLocalMutation()
            importProgress = nil
            await load()
        } catch {
            importProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    private func addYouTubeVideo() async {
        guard let assetManager = model.assetManager else { return }
        let cleanAddress = youtubeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanAddress) else {
            errorMessage = YouTubeReferenceError.invalidURL.localizedDescription
            return
        }
        isAddingYouTubeVideo = false
        importProgress = "Adding YouTube reference…"
        do {
            _ = try await assetManager.importYouTubeReference(
                from: url,
                title: youtubeTitle,
                topicId: youtubeTopicId
            )
            youtubeAddress = ""
            youtubeTitle = ""
            youtubeTopicId = nil
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

private struct WebSnapshotCaptureSheet: View {
    @Binding var address: String
    @Binding var topicId: UUID?
    let topics: [IdentifiedPayload<TopicPayload>]
    let capture: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Webpage") {
                    TextField("https://example.com/article", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("web-snapshot.address")
                    Text("Epistoria downloads one HTML snapshot. It does not keep browsing history, cookies, or a live connection to the page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Organization") {
                    Picker("Topic", selection: $topicId) {
                        Text("Unassigned Inbox").tag(UUID?.none)
                        ForEach(topics, id: \.id) { topic in
                            Text(topic.payload.name).tag(Optional(topic.id))
                        }
                    }
                }
                Section {
                    Text("Refreshing later is always manual and creates another immutable version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Capture webpage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Capture") { capture() }
                        .fontWeight(.semibold)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("web-snapshot.capture")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct GoogleWorkspaceCaptureSheet: View {
    @Binding var address: String
    @Binding var topicId: UUID?
    let topics: [IdentifiedPayload<TopicPayload>]
    let capture: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Google file") {
                    TextField("Paste a Google Docs, Slides, or Sheets link", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("google-workspace.address")
                    Text("The file must allow anyone with the link to view it. Epistoria downloads an Office-format copy without signing in to Google.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Organization") {
                    Picker("Topic", selection: $topicId) {
                        Text("Unassigned Inbox").tag(UUID?.none)
                        ForEach(topics, id: \.id) { topic in
                            Text(topic.payload.name).tag(Optional(topic.id))
                        }
                    }
                }
                Section {
                    Text("The downloaded copy is encrypted locally. Refresh is manual and creates another immutable version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Google file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { capture() }
                        .fontWeight(.semibold)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("google-workspace.capture")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct YouTubeCaptureSheet: View {
    @Binding var address: String
    @Binding var title: String
    @Binding var topicId: UUID?
    let topics: [IdentifiedPayload<TopicPayload>]
    let add: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("YouTube video") {
                    TextField("Paste a YouTube video link", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("youtube.address")
                    TextField("Title (optional)", text: $title)
                        .accessibilityIdentifier("youtube.title")
                    Text("Epistoria saves the reference. It does not download or cache the video or its captions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Organization") {
                    Picker("Topic", selection: $topicId) {
                        Text("Unassigned Inbox").tag(UUID?.none)
                        ForEach(topics, id: \.id) { topic in
                            Text(topic.payload.name).tag(Optional(topic.id))
                        }
                    }
                }
                Section {
                    Text("Playback requires a network connection. The privacy-enhanced YouTube player loads only after you choose to load it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add YouTube video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("youtube.add")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct SourceDetailView: View {
    @Bindable var model: AppModel
    let sourceId: UUID
    var sessionId: UUID?
    var initialPageNumber: Int?
    var focusedAnnotationId: UUID?
    var highlightText: String?
    var initialMediaTimeSeconds: Double?
    var initialHighlightRectangles: [AnnotationRectangle]

    @State private var resource: IdentifiedPayload<SourcePayload>?
    @State private var source: IdentifiedPayload<SourcePayload>?
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var lists: [IdentifiedPayload<ListPayload>] = []
    @State private var versions: [IdentifiedPayload<SourceVersionPayload>] = []
    @State private var selectedSourceVersionId: UUID?
    @State private var isOrganizing = false
    @State private var isComparing = false
    @State private var isRefreshingSource = false
    @State private var isRefreshingWebPage = false
    @State private var isRefreshingGoogleFile = false
    @State private var webSnapshotDifference: WebSnapshotDifference?
    @State private var snapshotChangeTitle = "Source refreshed"
    @State private var sourceData: Data?
    @State private var mediaPlaybackStartTime: Double?
    @State private var sourceFilenameExtension = "mp4"
    @State private var csvDocument: CSVSourceDocument?
    @State private var readableText: String?
    @State private var pageNumber = 1
    @State private var pageCount = 0
    @State private var annotations: [IdentifiedPayload<AnnotationPayload>] = []
    @State private var extraction: IdentifiedPayload<PDFExtractionManifest>?
    @State private var isExtractingText = false
    @State private var extractionStatusMessage: String?
    @State private var ocrArtifacts: [IdentifiedPayload<OCRArtifactPayload>] = []
    @State private var isShowingOCRReview = false
    @State private var sourceAnalysis: IdentifiedPayload<SourceAnalysisArtifact>?
    @State private var sourceQueries: [IdentifiedPayload<SourceQueryArtifact>] = []
    @State private var sourcePreparation: DirectSourcePreparation?
    @State private var sourceDisclosure: DirectProviderDisclosure?
    @State private var isApprovingSourceAnalysis = false
    @State private var isAskingSource = false
    @State private var sourceOutputLanguage = Locale.current.localizedString(
        forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en"
    ) ?? "English"
    @State private var sourceQuestion = ""
    @State private var includeSourceImages = true
    @State private var citationRectangles: [AnnotationRectangle] = []
    @State private var transcription: IdentifiedPayload<MediaTranscriptionManifest>?
    @State private var transcriptSegments: [TranscriptSegment] = []
    @State private var transcriptionDisclosure: DirectProviderDisclosure?
    @State private var sourceAsset: AssetPayload?
    @State private var isApprovingTranscription = false
    @State private var isShowingTranscript = false
    @State private var transcriptionLanguage = ""
    @State private var annotationKind = AnnotationKind.comment
    @State private var comment = ""
    @State private var isLoading = true
    @State private var isRecognizingSourcePages = false
    @State private var isInspectorPresented = true
    @State private var editingAnnotation: IdentifiedPayload<AnnotationPayload>?
    @State private var pendingDeletion: IdentifiedPayload<AnnotationPayload>?
    @State private var recentlyDeleted: IdentifiedPayload<AnnotationPayload>?
    @State private var hasRecordedSessionOpen = false
    @State private var errorMessage: String?
    @FocusState private var annotationEditorFocused: Bool

    init(
        model: AppModel,
        sourceId: UUID,
        sessionId: UUID? = nil,
        initialSourceVersionId: UUID? = nil,
        initialPageNumber: Int? = nil,
        focusedAnnotationId: UUID? = nil,
        highlightText: String? = nil,
        initialMediaTimeSeconds: Double? = nil,
        initialHighlightRectangles: [AnnotationRectangle] = []
    ) {
        self.model = model
        self.sourceId = sourceId
        self.sessionId = sessionId
        self.initialPageNumber = initialPageNumber
        self.focusedAnnotationId = focusedAnnotationId
        self.highlightText = highlightText
        self.initialMediaTimeSeconds = initialMediaTimeSeconds
        self.initialHighlightRectangles = initialHighlightRectangles
        _selectedSourceVersionId = State(initialValue: initialSourceVersionId)
        _pageNumber = State(initialValue: max(initialPageNumber ?? 1, 1))
        _mediaPlaybackStartTime = State(initialValue: initialMediaTimeSeconds)
        _citationRectangles = State(initialValue: initialHighlightRectangles)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Decrypting locally…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if resource?.payload.sourceType == .youtube,
                      let url = selectedYouTubeURL,
                      let reference = try? YouTubeReference(url: url) {
                YouTubeSourceView(reference: reference)
            } else if resource?.payload.sourceType == .website,
                      sourceData == nil,
                      let url = source?.payload.canonicalURL {
                SharedWebReferenceView(url: url) {
                    Task { await refreshWebPage() }
                }
            } else if let sourceData, resource?.payload.sourceType == .pdf {
                PDFDocumentView(
                    data: sourceData,
                    pageNumber: $pageNumber,
                    pageCount: $pageCount,
                    highlightText: highlightText,
                    highlightRectangles: citationRectangles
                )
            } else if let sourceData, resource?.payload.sourceType == .image,
                      let image = UIImage(data: sourceData) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().padding(24)
                }
            } else if let sourceData, resource?.payload.sourceType == .audio {
                AudioSourceView(data: sourceData, initialTime: mediaPlaybackStartTime)
                    .id(mediaPlaybackStartTime)
            } else if let sourceData, resource?.payload.sourceType == .video {
                VideoSourceView(
                    data: sourceData,
                    filenameExtension: sourceFilenameExtension,
                    initialTime: mediaPlaybackStartTime
                )
                .id(mediaPlaybackStartTime)
            } else if let document = csvDocument {
                CSVSourceView(document: document)
            } else if let readableText {
                StructuredSourceTextView(
                    text: readableText,
                    usesMonospacedText: resource?.payload.sourceType == .markdown
                )
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
        .navigationTitle(resource?.payload.title ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.learningLaunchContext = LearningLaunchContext(
                        topicId: source?.payload.primaryTopicId,
                        sourceVersionId: selectedSourceVersionId ?? source?.payload.currentVersionId,
                        destination: .overview
                    )
                    model.selectedSection = .learning
                } label: {
                    Label("Learn from this Source", systemImage: "graduationcap")
                }
                Button { isComparing = true } label: {
                    Label("Compare Sources", systemImage: "rectangle.split.2x1")
                }
                Button { isOrganizing = true } label: {
                    Label("Edit Source", systemImage: "slider.horizontal.3")
                }
                if resource?.payload.sourceType == .website {
                    Button { Task { await refreshWebPage() } } label: {
                        Label("Refresh webpage", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshingWebPage)
                    Button { isInspectorPresented.toggle() } label: {
                        Label(
                            isInspectorPresented ? "Hide Source details" : "Show Source details",
                            systemImage: "sidebar.trailing"
                        )
                    }
                } else if resource?.payload.sourceType.isGoogleWorkspaceSource == true {
                    Button { Task { await refreshGoogleFile() } } label: {
                        Label("Refresh Google file", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshingGoogleFile)
                    Button { isInspectorPresented.toggle() } label: {
                        Label(
                            isInspectorPresented ? "Hide Source details" : "Show Source details",
                            systemImage: "sidebar.trailing"
                        )
                    }
                } else if resource?.payload.sourceType == .youtube
                            || resource?.payload.sourceType == .audio
                            || resource?.payload.sourceType == .video {
                    Button { isInspectorPresented.toggle() } label: {
                        Label(
                            isInspectorPresented ? "Hide Source details" : "Show Source details",
                            systemImage: "sidebar.trailing"
                        )
                    }
                } else {
                    Button { isRefreshingSource = true } label: {
                        Label("Refresh Source", systemImage: "arrow.clockwise")
                    }
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
                if resource?.payload.sourceType == .pdf { Button {
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
        .onChange(of: includeSourceImages) { _, _ in
            guard isApprovingSourceAnalysis || isAskingSource else { return }
            Task { await prepareSourceApproval(forQuestion: isAskingSource) }
        }
        .fileImporter(
            isPresented: $isRefreshingSource,
            allowedContentTypes: EpistoriaSourceImportTypes.supported
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
        .fullScreenCover(isPresented: $isComparing) {
            SourceComparisonView(model: model, initialSourceId: sourceId)
        }
        .sheet(isPresented: $isApprovingTranscription) {
            MediaTranscriptionApprovalSheet(
                filename: sourceAsset?.originalFilename ?? resource?.payload.title ?? "Media Source",
                byteCount: sourceAsset?.plaintextByteSize ?? Int64(sourceData?.count ?? 0),
                disclosure: transcriptionDisclosure,
                language: $transcriptionLanguage
            ) {
                isApprovingTranscription = false
                Task { await queueTranscription() }
            }
        }
        .sheet(isPresented: $isApprovingSourceAnalysis) {
            SourceAIApprovalSheet(
                mode: .guide,
                filename: sourceAsset?.originalFilename ?? resource?.payload.title ?? "PDF Source",
                byteCount: sourceAsset?.plaintextByteSize ?? Int64(sourceData?.count ?? 0),
                disclosure: sourceDisclosure,
                pageCount: sourcePreparation?.pageCount ?? 0,
                referenceCount: sourcePreparation?.references.count ?? 0,
                outputLanguage: $sourceOutputLanguage,
                question: $sourceQuestion,
                includeImages: $includeSourceImages
            ) {
                isApprovingSourceAnalysis = false
                Task { await queueSourceAnalysis() }
            }
        }
        .sheet(isPresented: $isAskingSource) {
            SourceAIApprovalSheet(
                mode: .question,
                filename: sourceAsset?.originalFilename ?? resource?.payload.title ?? "PDF Source",
                byteCount: sourceAsset?.plaintextByteSize ?? Int64(sourceData?.count ?? 0),
                disclosure: sourceDisclosure,
                pageCount: sourcePreparation?.pageCount ?? 0,
                referenceCount: sourcePreparation?.references.count ?? 0,
                outputLanguage: $sourceOutputLanguage,
                question: $sourceQuestion,
                includeImages: $includeSourceImages
            ) {
                isAskingSource = false
                Task { await queueSourceQuery() }
            }
        }
        .sheet(isPresented: $isShowingTranscript) {
            MediaTranscriptView(
                model: model,
                title: resource?.payload.title ?? "Transcript",
                transcriptionArtifactId: transcription?.id,
                manifest: transcription?.payload,
                segments: transcriptSegments,
                accept: { Task { await reviewTranscription(.accepted) } },
                reject: { Task { await reviewTranscription(.rejected) } },
                openAtTime: { time in
                    mediaPlaybackStartTime = time
                    isShowingTranscript = false
                },
                changed: { Task { await load() } }
            )
        }
        .sheet(isPresented: $isShowingOCRReview) {
            OCRReviewView(
                model: model,
                parentId: sourceId,
                artifacts: $ocrArtifacts,
                onCreateEquation: nil
            )
        }
        .sheet(
            isPresented: Binding(
                get: { webSnapshotDifference != nil },
                set: { if !$0 { webSnapshotDifference = nil } }
            )
        ) {
            if let webSnapshotDifference {
                WebSnapshotChangesView(
                    difference: webSnapshotDifference,
                    title: snapshotChangeTitle
                )
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
            Text("The PDF itself is never changed. You can undo while this Source remains open.")
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
        .alert("Source error", isPresented: .constant(errorMessage != nil)) {
            Button("Try again") { Task { await load() } }
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var annotationInspector: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                if resource?.payload.sourceType == .pdf { Section {
                    Label("Original PDF preserved", systemImage: "lock.doc")
                        .foregroundStyle(.secondary)
                    Text("Annotations are separate encrypted records, so importing never modifies the source file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } }

                if resource?.payload.sourceType == .pdf { Section("Source guide") {
                    if let sourceAnalysis {
                        LabeledContent(
                            "Coverage",
                            value: "\(sourceAnalysis.payload.analyzedPageCount) of \(sourceAnalysis.payload.pageCount) pages"
                        )
                        ForEach(sourceAnalysis.payload.guide.summary) { statement in
                            citedStatement(
                                statement,
                                references: sourceAnalysis.payload.references
                            )
                        }
                        if !sourceAnalysis.payload.guide.translatedSummary.isEmpty {
                            DisclosureGroup("Translation · \(sourceAnalysis.payload.guide.outputLanguage)") {
                                ForEach(sourceAnalysis.payload.guide.translatedSummary) { statement in
                                    citedStatement(
                                        statement,
                                        references: sourceAnalysis.payload.references
                                    )
                                }
                            }
                        }
                        if !sourceAnalysis.payload.guide.imageInsights.isEmpty {
                            DisclosureGroup("Images and figures") {
                                ForEach(sourceAnalysis.payload.guide.imageInsights) { statement in
                                    citedStatement(
                                        statement,
                                        references: sourceAnalysis.payload.references
                                    )
                                }
                            }
                        }
                        if !sourceAnalysis.payload.guide.keyTopics.isEmpty {
                            DisclosureGroup("Key topics") {
                                ForEach(sourceAnalysis.payload.guide.keyTopics) { topic in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(topic.title).font(.subheadline.weight(.semibold))
                                        Text(topic.explanation).font(.subheadline)
                                        citationLinks(
                                            topic.sourceIds,
                                            references: sourceAnalysis.payload.references
                                        )
                                    }
                                }
                            }
                        }
                        if !sourceAnalysis.payload.guide.suggestedQuestions.isEmpty {
                            DisclosureGroup("Suggested questions") {
                                ForEach(sourceAnalysis.payload.guide.suggestedQuestions) { item in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Button {
                                            sourceQuestion = item.question
                                            Task { await prepareSourceApproval(forQuestion: true) }
                                        } label: {
                                            Text(item.question)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .buttonStyle(.plain)
                                        citationLinks(
                                            item.sourceIds,
                                            references: sourceAnalysis.payload.references
                                        )
                                    }
                                }
                            }
                        }
                        if !sourceAnalysis.payload.guide.coverageGaps.isEmpty {
                            DisclosureGroup("Coverage limits") {
                                ForEach(sourceAnalysis.payload.guide.coverageGaps, id: \.self) {
                                    Text($0).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Refresh source guide…", systemImage: "arrow.clockwise") {
                            Task { await prepareSourceApproval(forQuestion: false) }
                        }
                    } else {
                        Button("Analyze this Source…", systemImage: "doc.text.magnifyingglass") {
                            Task { await prepareSourceApproval(forQuestion: false) }
                        }
                        Text("Creates a cited summary, translation, key topics, suggested questions, and figure notes for the current immutable Source Version.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Ask this Source…", systemImage: "questionmark.bubble") {
                        Task { await prepareSourceApproval(forQuestion: true) }
                    }
                    .disabled(sourceData == nil)
                } }

                if resource?.payload.sourceType == .pdf, !sourceQueries.isEmpty {
                    Section("Source answers") {
                        ForEach(sourceQueries.prefix(5), id: \.id) { artifact in
                            DisclosureGroup(artifact.payload.question) {
                                ForEach(artifact.payload.response.answer) { statement in
                                    citedStatement(
                                        statement,
                                        references: artifact.payload.references
                                    )
                                }
                                if artifact.payload.response.insufficientEvidence {
                                    Label("The cited material was insufficient.", systemImage: "exclamationmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if resource?.payload.sourceType == .pdf { Section("Searchable text") {
                    if let extraction {
                        Label("\(extraction.payload.pageCount) pages indexed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(EpistoriaDesign.positive)
                        LabeledContent(
                            "Characters",
                            value: extraction.payload.characterCount.formatted()
                        )
                        if !extraction.payload.pagesNeedingOcr.isEmpty {
                            Text("Pages without embedded text: \(extraction.payload.pagesNeedingOcr.map(String.init).joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(EpistoriaDesign.attention)
                        }
                        if isRecognizingSourcePages {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Recognizing scanned pages privately on this iPad…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !ocrArtifacts.isEmpty {
                            Button("Review recognized pages (\(ocrArtifacts.count))") {
                                isShowingOCRReview = true
                            }
                            Label("Local OCR finished. Review the recognized pages before using them for learning.", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(EpistoriaDesign.positive)
                        }
                    } else {
                        Button {
                            Task { await queueExtraction() }
                        } label: {
                            if isExtractingText {
                                Label("Extracting text…", systemImage: "text.viewfinder")
                            } else {
                                Label("Extract text on this iPad", systemImage: "text.viewfinder")
                            }
                        }
                        .disabled(isExtractingText)
                        if isExtractingText {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Reading embedded text privately on this iPad. You can keep using the Source after this finishes.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("This local operation does not call an AI provider. The decrypted PDF remains in iPad memory while text is extracted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let extractionStatusMessage {
                        Label(extractionStatusMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(EpistoriaDesign.positive)
                    }
                } }

                if resource?.payload.sourceType == .image, !ocrArtifacts.isEmpty {
                    Section("Recognized text") {
                        Button("Review recognized image (\(ocrArtifacts.count))") {
                            isShowingOCRReview = true
                        }
                        Text("Unreviewed text is labeled in local search and is not used for learning features.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if resource?.payload.sourceType == .website {
                    Section("Captured webpage") {
                        if let canonicalURL = source?.payload.canonicalURL {
                            LabeledContent("Address") {
                                Text(canonicalURL.absoluteString)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                        }
                        Text(sourceData == nil
                            ? "This shared link has not been fetched. Capture it to create an encrypted offline snapshot."
                            : "This is a local snapshot. The page is never refreshed automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if resource?.payload.sourceType.isGoogleWorkspaceSource == true {
                    Section("Captured Google file") {
                        if let canonicalURL = source?.payload.canonicalURL {
                            LabeledContent("Share link") {
                                Text(canonicalURL.absoluteString)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                        }
                        Text("This is an encrypted offline copy. Epistoria does not sign in to Google and never refreshes it automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if resource?.payload.sourceType == .youtube {
                    Section("YouTube reference") {
                        if let url = selectedYouTubeURL {
                            LabeledContent("Video link") {
                                Text(url.absoluteString)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                        }
                        Text("Epistoria stores this link. Video playback uses YouTube's privacy-enhanced online player only after you choose Load video.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if resource?.payload.sourceType == .audio
                    || resource?.payload.sourceType == .video {
                    Section("Transcript") {
                        if let transcription {
                            Button("Read timestamped transcript", systemImage: "text.quote") {
                                isShowingTranscript = true
                            }
                            if let state = transcription.payload.reviewState {
                                LabeledContent("Review", value: state.rawValue.capitalized)
                            } else {
                                Label("Needs review", systemImage: "exclamationmark.circle")
                                    .foregroundStyle(EpistoriaDesign.attention)
                            }
                            LabeledContent(
                                "Length",
                                value: mediaTimeLabel(transcription.payload.durationSeconds)
                            )
                            LabeledContent(
                                "Segments",
                                value: transcription.payload.segmentCount.formatted()
                            )
                            Text("This encrypted transcript is bound to Source Version \(transcription.payload.sourceVersionId.uuidString).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !canTranscribeCurrentMedia {
                            Label(
                                "Transcription supports MP3, M4A, WAV, and MP4 in this stage.",
                                systemImage: "info.circle"
                            )
                            .foregroundStyle(.secondary)
                        } else {
                            Button("Transcribe…", systemImage: "waveform.badge.mic") {
                                Task { await prepareTranscriptionApproval() }
                            }
                            .disabled(sourceData == nil)
                            Text("Transcription is optional. Approval is required because the configured provider receives the media bytes directly from this iPad.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Versions") {
                    ForEach(versions, id: \.id) { version in
                        Button {
                            guard resource?.payload.sourceType == .website
                                    || resource?.payload.sourceType.isGoogleWorkspaceSource == true
                            else { return }
                            selectedSourceVersionId = version.id
                            Task { await load() }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("Version \(version.payload.versionNumber)")
                                    Spacer()
                                    if version.id == selectedSourceVersionId
                                        || (selectedSourceVersionId == nil
                                            && version.id == source?.payload.currentVersionId) {
                                        Text("Viewing").font(.caption.bold())
                                    } else if version.id == source?.payload.currentVersionId {
                                        Text("Current").font(.caption.bold())
                                    }
                                }
                                if let capturedURL = version.payload.capturedURL {
                                    Text(capturedURL.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            resource?.payload.sourceType != .website
                                && resource?.payload.sourceType.isGoogleWorkspaceSource != true
                        )
                    }
                    Text("Refresh creates a new immutable version. Existing citations and study records keep their original version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if resource?.payload.sourceType == .pdf { Section("Add to page \(pageNumber)") {
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
                } }

                if resource?.payload.sourceType == .pdf { Section("Annotations") {
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
                } }
                }
                .navigationTitle(
                    resource?.payload.sourceType == .website
                        || resource?.payload.sourceType.isGoogleWorkspaceSource == true
                        || resource?.payload.sourceType == .youtube
                        || resource?.payload.sourceType == .audio
                        || resource?.payload.sourceType == .video
                        ? "Source details"
                        : "Notes"
                )
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

    private var selectedYouTubeURL: URL? {
        let selectedVersion = versions.first { version in
            version.id == (selectedSourceVersionId ?? source?.payload.currentVersionId)
        }
        return selectedVersion?.payload.capturedURL ?? source?.payload.canonicalURL
    }

    private func citedStatement(
        _ statement: SourceGuideStatement,
        references: [SourceCitationReference]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statement.text)
                .font(.subheadline)
                .textSelection(.enabled)
            citationLinks(statement.sourceIds, references: references)
        }
        .padding(.vertical, 3)
    }

    private func citationLinks(
        _ sourceIds: [UUID],
        references: [SourceCitationReference]
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(sourceIds.prefix(4).enumerated()), id: \.element) { index, sourceId in
                if let reference = references.first(where: { $0.sourceId == sourceId }) {
                    Button {
                        openCitation(sourceId, references: references)
                    } label: {
                        Label(
                            "\(reference.pageNumber)",
                            systemImage: reference.kind == .image ? "photo" : "doc.text"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel(
                        "Open citation \(index + 1) on PDF page \(reference.pageNumber)"
                    )
                }
            }
        }
    }

    private var canTranscribeCurrentMedia: Bool {
        guard let filename = sourceAsset?.originalFilename else { return false }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if resource?.payload.sourceType == .audio {
            return ["mp3", "m4a", "wav"].contains(ext)
        }
        return resource?.payload.sourceType == .video && ext == "mp4"
    }

    private func load() async {
        guard let store = model.store else { return }
        isLoading = true
        errorMessage = nil
        sourceData = nil
        sourceFilenameExtension = "mp4"
        csvDocument = nil
        readableText = nil
        sourceAsset = nil
        transcription = nil
        transcriptSegments = []
        do {
            let loaded = try await store.payload(SourcePayload.self, id: sourceId)
            async let loadedSource = store.payload(SourcePayload.self, id: sourceId)
            async let loadedTopics = store.topics()
            async let loadedLists = store.lists()
            resource = loaded
            let resolvedSource = try await loadedSource
            source = resolvedSource
            topics = try await loadedTopics.filter { !$0.payload.archived }
            lists = try await loadedLists.filter { $0.payload.archivedAt == nil }
            versions = try await store.list(SourceVersionPayload.self, parentId: sourceId)
                .sorted { $0.payload.versionNumber > $1.payload.versionNumber }
            annotations = try await store.list(AnnotationPayload.self)
                .filter { $0.payload.sourceId == sourceId }
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
            if loaded.payload.sourceType == .pdf || loaded.payload.sourceType == .image {
                extraction = try await model.aiJobs?.latestPDFExtraction(sourceId: sourceId)
                ocrArtifacts = try await store.ocrArtifacts(parentId: sourceId)
                if let currentVersionId = resolvedSource.payload.currentVersionId,
                   let coordinator = model.aiJobs {
                    sourceAnalysis = try await coordinator.latestSourceAnalysis(
                        sourceId: sourceId,
                        sourceVersionId: currentVersionId
                    )
                    sourceQueries = try await coordinator.sourceQueryArtifacts(
                        sourceId: sourceId,
                        sourceVersionId: currentVersionId
                    )
                }
            } else {
                extraction = nil
                ocrArtifacts = []
                sourceAnalysis = nil
                sourceQueries = []
            }
            let selectedVersion = versions.first { version in
                version.id == (selectedSourceVersionId ?? resolvedSource.payload.currentVersionId)
            }
            let displayedAssetId = selectedVersion?.payload.originalAssetId
                ?? loaded.payload.originalAssetId
            if let assetId = displayedAssetId, let assetManager = model.assetManager {
                if let metadata = try? await store.payload(AssetPayload.self, id: assetId).payload {
                    sourceAsset = metadata
                    let ext = URL(fileURLWithPath: metadata.originalFilename).pathExtension.lowercased()
                    if loaded.payload.sourceType == .video,
                       ["m4v", "mov", "mp4"].contains(ext) {
                        sourceFilenameExtension = ext
                    }
                }
                let data = try await assetManager.decryptedData(assetId: assetId)
                sourceData = data
                let prepared = try await Self.prepareReaderContent(
                    data: data,
                    sourceType: loaded.payload.sourceType
                )
                csvDocument = prepared.csv
                readableText = prepared.text
                if loaded.payload.sourceType == .image,
                   let selectedVersion,
                   model.localProcessingSettings.automaticSourceOCR
                {
                    await recognizeSourceImageIfNeeded(
                        data: data,
                        version: selectedVersion,
                        store: store
                    )
                }
                if loaded.payload.sourceType == .pdf,
                   let selectedVersion,
                   let extraction,
                   !extraction.payload.pagesNeedingOcr.isEmpty,
                   model.localProcessingSettings.automaticSourceOCR
                {
                    Task {
                        await recognizeSourcePDFPagesIfNeeded(
                            data: data,
                            pageNumbers: extraction.payload.pagesNeedingOcr,
                            version: selectedVersion,
                            store: store
                        )
                    }
                }
            }
            if (loaded.payload.sourceType == .audio || loaded.payload.sourceType == .video),
               let currentVersionId = resolvedSource.payload.currentVersionId,
               let coordinator = model.aiJobs {
                transcription = try await coordinator.latestMediaTranscription(
                    sourceId: sourceId,
                    sourceVersionId: currentVersionId
                )
                if let transcription {
                    transcriptSegments = try await coordinator.mediaTranscriptionSegments(
                        manifest: transcription.payload
                    )
                }
            }
            let supportsInspector = loaded.payload.sourceType == .pdf
                || loaded.payload.sourceType == .image
                || loaded.payload.sourceType == .website
                || loaded.payload.sourceType.isGoogleWorkspaceSource
                || loaded.payload.sourceType == .youtube
                || loaded.payload.sourceType == .audio
                || loaded.payload.sourceType == .video
            if !supportsInspector {
                isInspectorPresented = false
            }
            if let sessionId, !hasRecordedSessionOpen,
               let session = try? await store.payload(StudySessionPayload.self, id: sessionId),
               session.payload.state == .active || session.payload.state == .paused
            {
                _ = try await store.recordSessionActivity(
                    sessionId: sessionId,
                    itemId: sourceId,
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

    fileprivate static func prepareReaderContent(
        data: Data,
        sourceType: SourceKind
    ) async throws -> PreparedSourceContent {
        try await Task.detached(priority: .userInitiated) {
            if sourceType == .csv {
                return PreparedSourceContent(csv: try CSVSourceAdapter().parse(data: data))
            }
            switch sourceType {
            case .epub, .docx, .odt, .pptx, .odp, .xlsx, .html, .website,
                    .googleDocument, .googleSlides, .googleSheet:
                let adapter = try SourceAdapterRegistry().adapter(for: sourceType)
                return PreparedSourceContent(text: try adapter.extractText(data: data))
            case .pastedText, .markdown:
                guard let text = String(data: data, encoding: .utf8) else {
                    throw SourceAdapterError.malformed
                }
                return PreparedSourceContent(text: text)
            default:
                return PreparedSourceContent()
            }
        }.value
    }

    private func recognizeSourceImageIfNeeded(
        data: Data,
        version: IdentifiedPayload<SourceVersionPayload>,
        store: EpistoriaStore
    ) async {
        guard let accountId = model.configuration?.accountId,
              !ocrArtifacts.contains(where: {
                  $0.payload.sourceVersionId == version.id
                      && $0.payload.inputRevision == version.revision
                      && $0.payload.response.engine == .appleVision
                      && $0.payload.state == .current
              })
        else { return }
        do {
            let capture = try await LocalTextOCRService.recognizeImage(
                accountId: accountId,
                sourceId: sourceId,
                sourceVersionId: version.id,
                inputRevision: version.revision,
                imageData: data,
                preferredLanguages: model.localProcessingSettings.normalizedLanguages
            )
            _ = try await store.saveOCRArtifact(
                request: capture.request,
                response: capture.response
            )
            let recognized = capture.response.regions.map(\.text).joined(separator: " ")
            let mathCharacters = CharacterSet(charactersIn: "=+−-×÷/^√∫∑()[]{}<>²³")
            if model.localProcessingSettings.localMathOCR,
               recognized.rangeOfCharacter(from: mathCharacters) != nil,
               FormulaModelRegistry.productionManifest != nil
            {
                var formulaRequest = capture.request
                formulaRequest.jobId = UUID()
                formulaRequest.mode = .formula
                let formulaResponse = try await model.recognizeFormulaOnDevice(formulaRequest)
                _ = try await store.saveOCRArtifact(
                    request: formulaRequest,
                    response: formulaResponse
                )
            }
            ocrArtifacts = try await store.ocrArtifacts(parentId: sourceId)
            model.noteLocalMutation()
        } catch {
            // The original image remains readable. Recognition can be retried by reopening it.
        }
    }

    private func recognizeSourcePDFPagesIfNeeded(
        data: Data,
        pageNumbers: [Int],
        version: IdentifiedPayload<SourceVersionPayload>,
        store: EpistoriaStore
    ) async {
        guard !isRecognizingSourcePages,
              let accountId = model.configuration?.accountId,
              let document = PDFDocument(data: data)
        else { return }
        isRecognizingSourcePages = true
        defer { isRecognizingSourcePages = false }
        var known = Set(ocrArtifacts.compactMap { artifact -> Int? in
            guard artifact.payload.sourceVersionId == version.id,
                  artifact.payload.inputRevision == version.revision,
                  artifact.payload.response.engine == .appleVision,
                  artifact.payload.state == .current
            else { return nil }
            return artifact.payload.pageNumber
        })
        for pageNumber in Array(Set(pageNumbers)).sorted() where !known.contains(pageNumber) {
            guard !Task.isCancelled,
                  pageNumber >= 1,
                  let page = document.page(at: pageNumber - 1)
            else { continue }
            do {
                let image = page.thumbnail(
                    of: CGSize(width: 1_600, height: 2_200),
                    for: .mediaBox
                )
                guard let imageData = image.jpegData(compressionQuality: 0.82) else { continue }
                let capture = try await LocalTextOCRService.recognizeSourcePage(
                    accountId: accountId,
                    sourceId: sourceId,
                    sourceVersionId: version.id,
                    inputRevision: version.revision,
                    pageNumber: pageNumber,
                    imageData: imageData,
                    preferredLanguages: model.localProcessingSettings.normalizedLanguages
                )
                _ = try await store.saveOCRArtifact(
                    request: capture.request,
                    response: capture.response
                )
                known.insert(pageNumber)
            } catch {
                // Keep the page available. Reopening the Source retries local recognition.
            }
        }
        ocrArtifacts = (try? await store.ocrArtifacts(parentId: sourceId)) ?? ocrArtifacts
        model.noteLocalMutation()
    }

    private func refreshSource(_ result: Result<URL, Error>) async {
        guard let manager = model.assetManager else { return }
        do {
            _ = try await manager.refreshSource(id: sourceId, from: result.get())
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshWebPage() async {
        guard let manager = model.assetManager else { return }
        isRefreshingWebPage = true
        defer { isRefreshingWebPage = false }
        do {
            let refreshed = try await manager.refreshWebSnapshot(id: sourceId)
            selectedSourceVersionId = nil
            snapshotChangeTitle = "Webpage refreshed"
            webSnapshotDifference = refreshed.difference
            model.noteLocalMutation()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshGoogleFile() async {
        guard let manager = model.assetManager else { return }
        isRefreshingGoogleFile = true
        defer { isRefreshingGoogleFile = false }
        do {
            let refreshed = try await manager.refreshGoogleWorkspaceSnapshot(id: sourceId)
            selectedSourceVersionId = nil
            snapshotChangeTitle = "Google file refreshed"
            webSnapshotDifference = refreshed.difference
            model.noteLocalMutation()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAnnotation() async {
        guard let store = model.store else { return }
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            var payload = AnnotationPayload(
                sourceId: sourceId,
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
                    parentId: sourceId,
                    relationIds: [sourceId, sessionId].compactMap(\.self)
                )
            }
            comment = ""
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func queueExtraction() async {
        guard !isExtractingText else { return }
        isExtractingText = true
        extractionStatusMessage = nil
        defer { isExtractingText = false }
        do {
            _ = try await model.extractPDFOnDevice(sourceId: sourceId)
            model.noteLocalMutation()
            await load()
            if let extraction {
                if extraction.payload.pagesNeedingOcr.isEmpty {
                    extractionStatusMessage = "Text extraction finished. This Source is searchable."
                } else {
                    let count = extraction.payload.pagesNeedingOcr.count
                    extractionStatusMessage = "Embedded text extraction finished. \(count) page\(count == 1 ? "" : "s") still need\(count == 1 ? "s" : "") OCR."
                }
            } else {
                extractionStatusMessage = "Text extraction finished."
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func prepareTranscriptionApproval() async {
        do {
            transcriptionDisclosure = try model.directTranscriptionDisclosure()
            isApprovingTranscription = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func queueTranscription() async {
        guard let transcriptionDisclosure else { return }
        do {
            _ = try await model.transcribeSourceDirect(
                sourceId: sourceId,
                language: transcriptionLanguage,
                approvedRoute: transcriptionDisclosure.route
            )
            model.noteLocalMutation()
            self.transcriptionDisclosure = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareSourceApproval(forQuestion: Bool) async {
        do {
            let preparation = try await model.prepareDirectSource(
                sourceId: sourceId,
                includeImages: includeSourceImages
            )
            let disclosure = try model.directProviderDisclosure(
                approximateInputTokens: preparation.approximateTokens,
                maximumOutputTokens: forQuestion ? 6_000 : 8_000,
                requiresVision: !preparation.images.isEmpty
            )
            sourcePreparation = preparation
            sourceDisclosure = disclosure
            if forQuestion {
                isAskingSource = true
            } else {
                isApprovingSourceAnalysis = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func queueSourceAnalysis() async {
        guard let sourcePreparation, let sourceDisclosure else { return }
        do {
            _ = try await model.generateSourceAnalysisDirect(
                preparation: sourcePreparation,
                outputLanguage: sourceOutputLanguage,
                approvedRoute: sourceDisclosure.route
            )
            model.noteLocalMutation()
            self.sourcePreparation = nil
            self.sourceDisclosure = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func queueSourceQuery() async {
        guard let sourcePreparation, let sourceDisclosure else { return }
        do {
            _ = try await model.generateSourceQueryDirect(
                preparation: sourcePreparation,
                question: sourceQuestion,
                outputLanguage: sourceOutputLanguage,
                approvedRoute: sourceDisclosure.route
            )
            model.noteLocalMutation()
            sourceQuestion = ""
            self.sourcePreparation = nil
            self.sourceDisclosure = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openCitation(
        _ sourceId: UUID,
        references: [SourceCitationReference]
    ) {
        guard let reference = references.first(where: { $0.sourceId == sourceId }) else { return }
        citationRectangles = reference.rectangles
        pageNumber = reference.pageNumber
    }

    private func reviewTranscription(_ state: AIArtifactReviewState) async {
        guard let store = model.store, var transcription else { return }
        transcription.payload.reviewState = state
        transcription.payload.reviewedAt = .now
        do {
            _ = try await store.save(
                id: transcription.id,
                payload: transcription.payload,
                parentId: sourceId,
                relationIds: [sourceId, transcription.payload.sourceVersionId]
                    + transcription.payload.chunkEntityIds
            )
            self.transcription = transcription
            model.noteLocalMutation()
        } catch {
            errorMessage = error.localizedDescription
        }
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
                parentId: sourceId,
                relationIds: [
                    Optional(sourceId),
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

private struct YouTubeSourceView: View {
    let reference: YouTubeReference

    @State private var isLoaded = false

    var body: some View {
        Group {
            if isLoaded {
                YouTubeEmbedWebView(url: reference.embedURL)
                    .overlay(alignment: .topTrailing) {
                        Button("Unload video", systemImage: "xmark") {
                            isLoaded = false
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .background(.regularMaterial, in: Circle())
                        .padding()
                        .accessibilityHint("Stops the player and clears its temporary web data")
                    }
            } else {
                ContentUnavailableView {
                    Label("YouTube video", systemImage: "play.rectangle")
                } description: {
                    Text("Loading connects to YouTube. Playback requires a network connection and follows YouTube's privacy terms.")
                } actions: {
                    Button("Load video") { isLoaded = true }
                        .buttonStyle(.borderedProminent)
                        .tint(EpistoriaDesign.ink)
                    Link("Open in YouTube", destination: reference.playbackURL)
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("youtube.source")
    }
}

private struct YouTubeEmbedWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let host = navigationAction.request.url?.host?.lowercased() else {
                return .cancel
            }
            let allowed = host == "www.youtube-nocookie.com"
                || host == "youtube-nocookie.com"
                || host.hasSuffix(".youtube.com")
                || host == "youtube.com"
            return allowed ? .allow : .cancel
        }
    }
}

private struct SourceAIApprovalSheet: View {
    enum Mode: Equatable {
        case guide
        case question

        var title: String { self == .guide ? "Approve source analysis" : "Ask this Source" }
        var action: String { self == .guide ? "Approve and analyze" : "Approve and ask" }
    }

    let mode: Mode
    let filename: String
    let byteCount: Int64
    let disclosure: DirectProviderDisclosure?
    let pageCount: Int
    let referenceCount: Int
    @Binding var outputLanguage: String
    @Binding var question: String
    @Binding var includeImages: Bool
    let approve: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Source Version") {
                    LabeledContent("File", value: filename)
                    LabeledContent(
                        "Size",
                        value: ByteCountFormatter.string(
                            fromByteCount: byteCount, countStyle: .file
                        )
                    )
                }
                if mode == .question {
                    Section("Question") {
                        TextField("Ask about this PDF", text: $question, axis: .vertical)
                            .lineLimit(3 ... 8)
                    }
                }
                Section("Output language") {
                    TextField("Language, such as English or Spanish", text: $outputLanguage)
                    Text("The source summary stays in its detected language. Epistoria also asks for a translated summary or answer in this language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Figures") {
                    Toggle("Include rendered pages with figures", isOn: $includeImages)
                    Text("Turn this off to reduce input cost or use a text-only provider. The guide or answer will not evaluate PDF images.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Before you approve") {
                    LabeledContent(
                        "Maximum text input",
                        value: mode == .guide ? "About 45,000 tokens" : "About 27,000 tokens"
                    )
                    LabeledContent(
                        "Maximum figure input",
                        value: includeImages ? "8 images" : "None"
                    )
                    LabeledContent("Pages", value: pageCount.formatted())
                    LabeledContent("Citable regions", value: referenceCount.formatted())
                    if let disclosure {
                        LabeledContent("Provider", value: disclosure.provider)
                        LabeledContent("Model", value: disclosure.model)
                        LabeledContent("Destination", value: disclosure.destination)
                        LabeledContent(
                            "Maximum estimated cost",
                            value: disclosure.maximumEstimatedCostUsd.map {
                                $0.formatted(.currency(code: "USD"))
                            } ?? "Not available"
                        )
                    }
                    Label("This iPad decrypts and reads the PDF for this request.", systemImage: "ipad")
                    Label(
                        includeImages
                            ? "The active AI provider receives selected text and bounded figure images."
                            : "The active AI provider receives selected text only.",
                        systemImage: "network"
                    )
                    Label("Every result is encrypted and bound to this exact Source Version.", systemImage: "lock.doc")
                    Text("The sync service receives only encrypted content. The original PDF is not changed. Large PDFs report any pages or passages omitted from the current analysis pass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Actual charges depend on the active provider and model. Epistoria records the provider-reported token use and configured cost estimate on the result.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.action) { approve() }
                        .fontWeight(.semibold)
                        .disabled(
                            byteCount <= 0
                                || outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || disclosure == nil
                                || (mode == .question
                                    && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MediaTranscriptionApprovalSheet: View {
    let filename: String
    let byteCount: Int64
    let disclosure: DirectProviderDisclosure?
    @Binding var language: String
    let approve: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Media") {
                    LabeledContent("File", value: filename)
                    LabeledContent("Size", value: formattedSize)
                }
                Section("Optional language") {
                    TextField("Language code, such as en or es", text: $language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Leave this empty to let the provider detect the language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Before you approve") {
                    if let disclosure {
                        LabeledContent("Provider", value: disclosure.provider)
                        LabeledContent("Model", value: disclosure.model)
                        LabeledContent("Destination", value: disclosure.destination)
                        LabeledContent("Maximum estimated cost", value: "Calculated from returned duration")
                    }
                    Label("This iPad decrypts the Source for this request.", systemImage: "ipad")
                    Label("The configured AI provider receives the media bytes.", systemImage: "network")
                    Label("The returned transcript is encrypted and bound to this Source Version.", systemImage: "lock.doc")
                    Text("The sync service does not receive plaintext media or transcript content. The original Source is not changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if byteCount > 25 * 1_024 * 1_024 {
                    Section {
                        Label("This file exceeds the current 25 MB transcription limit.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(EpistoriaDesign.attention)
                    }
                }
            }
            .navigationTitle("Approve transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve and transcribe") { approve() }
                        .fontWeight(.semibold)
                        .disabled(
                            byteCount <= 0 || byteCount > 25 * 1_024 * 1_024
                                || disclosure == nil
                        )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MediaTranscriptView: View {
    @Bindable var model: AppModel
    let title: String
    let transcriptionArtifactId: UUID?
    let manifest: MediaTranscriptionManifest?
    let segments: [TranscriptSegment]
    let accept: () -> Void
    let reject: () -> Void
    let openAtTime: (Double) -> Void
    let changed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var reviewedManifest: MediaTranscriptionManifest?
    @State private var reviewedSegments: [ReviewedTranscriptSegment] = []
    @State private var corrections: [IdentifiedPayload<TranscriptCorrectionPayload>] = []
    @State private var selectedSegmentIndexes: Set<Int> = []
    @State private var selectionAnchor: Int?
    @State private var editingSegment: ReviewedTranscriptSegment?
    @State private var isCreatingEvidence = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var displayManifest: MediaTranscriptionManifest? { reviewedManifest ?? manifest }

    private var effectiveSegments: [ReviewedTranscriptSegment] {
        reviewedSegments.isEmpty
            ? segments.map { ReviewedTranscriptSegment(original: $0, text: $0.text, correctionId: nil) }
            : reviewedSegments
    }

    private var visibleSegments: [ReviewedTranscriptSegment] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return effectiveSegments }
        return effectiveSegments.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || $0.original.text.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedSegments: [ReviewedTranscriptSegment] {
        effectiveSegments.filter { selectedSegmentIndexes.contains($0.id) }
    }

    private var canCreateEvidence: Bool {
        guard let state = displayManifest?.reviewState else { return false }
        return correctionConflicts.isEmpty
            && !selectedSegmentIndexes.isEmpty
            && (state == .accepted || state == .edited)
    }

    private var correctionConflicts: [TranscriptCorrectionConflictGroup] {
        Dictionary(
            grouping: corrections.filter { $0.payload.state == .active },
            by: \ .payload.segmentIndex
        )
        .filter { $0.value.count > 1 }
        .map {
            TranscriptCorrectionConflictGroup(
                segmentIndex: $0.key,
                candidates: $0.value.sorted {
                    if $0.payload.createdAt == $1.payload.createdAt {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return $0.payload.createdAt < $1.payload.createdAt
                }
            )
        }
        .sorted { $0.segmentIndex < $1.segmentIndex }
    }

    var body: some View {
        NavigationStack {
            List {
                if let manifest = displayManifest {
                    Section {
                        LabeledContent("Duration", value: mediaTimeLabel(manifest.durationSeconds))
                        LabeledContent("Segments", value: manifest.segmentCount.formatted())
                        if let language = manifest.language, !language.isEmpty {
                            LabeledContent("Language", value: language)
                        }
                    } footer: {
                        Text("Generated by \(manifest.trace.provider) using \(manifest.trace.model). Provider text remains unchanged when you save a correction.")
                    }
                    reviewSection(manifest)
                }

                if !selectedSegmentIndexes.isEmpty {
                    Section("Evidence selection") {
                        LabeledContent("Range", value: selectedRangeLabel)
                        LabeledContent("Segments", value: selectedSegmentIndexes.count.formatted())
                        Button("Create timestamped Evidence…", systemImage: "quote.bubble") {
                            isCreatingEvidence = true
                        }
                        .disabled(!canCreateEvidence)
                        Button("Clear selection", systemImage: "xmark") { clearSelection() }
                        if !canCreateEvidence {
                            Text(correctionConflicts.isEmpty
                                ? "Accept or correct the transcript before creating Evidence."
                                : "Resolve correction conflicts before creating Evidence.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                if !correctionConflicts.isEmpty {
                    Section("Correction conflicts") {
                        ForEach(correctionConflicts) { conflict in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(conflictTimeLabel(conflict.segmentIndex))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("Corrections from different devices are active. Choose one or restore generated text.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(conflict.candidates, id: \ .id) { candidate in
                                    Button {
                                        Task {
                                            await resolveCorrectionConflict(
                                                segmentIndex: conflict.segmentIndex,
                                                keeping: candidate.id
                                            )
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(candidate.payload.correctedText)
                                            if let reason = candidate.payload.reason {
                                                Text(reason).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Text("Keep this correction")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Button("Use generated text", systemImage: "arrow.uturn.backward") {
                                    Task {
                                        await resolveCorrectionConflict(
                                            segmentIndex: conflict.segmentIndex,
                                            keeping: nil
                                        )
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Transcript") {
                    if visibleSegments.isEmpty {
                        Text(searchText.isEmpty ? "No transcript segments are available." : "No matching transcript text.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleSegments) { segment in
                        transcriptRow(segment)
                            .listRowBackground(
                                selectedSegmentIndexes.contains(segment.id)
                                    ? EpistoriaDesign.ink.opacity(0.08)
                                    : Color.clear
                            )
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search transcript")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadReviewedTranscript() }
        .sheet(item: $editingSegment) { segment in
            TranscriptCorrectionEditor(
                segment: segment,
                history: corrections.filter { $0.payload.segmentIndex == segment.id },
                save: { correctedText, reason in
                    try await saveCorrection(
                        segmentIndex: segment.id,
                        correctedText: correctedText,
                        reason: reason
                    )
                },
                retract: segment.correctionId == nil ? nil : {
                    try await retractCorrection(segment.correctionId)
                }
            )
        }
        .sheet(isPresented: $isCreatingEvidence) {
            TranscriptEvidenceEditor(
                title: title,
                segments: selectedSegments,
                create: { note in try await createEvidence(note: note) }
            )
        }
        .alert("Transcript problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func reviewSection(_ manifest: MediaTranscriptionManifest) -> some View {
        Section("Review") {
            if let state = manifest.reviewState {
                LabeledContent("Status", value: state.rawValue.capitalized)
            } else {
                Button("Accept transcript", systemImage: "checkmark") {
                    accept()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(EpistoriaDesign.ink)
                Button("Reject transcript", systemImage: "xmark", role: .destructive) {
                    reject()
                    dismiss()
                }
                Text("Accepting includes the transcript in derived-data exports. Rejecting keeps it out. Neither action changes the media Source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transcriptRow(_ segment: ReviewedTranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selectedSegmentIndexes.contains(segment.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedSegmentIndexes.contains(segment.id) ? .primary : .tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("\(mediaTimeLabel(segment.original.startSeconds))–\(mediaTimeLabel(segment.original.endSeconds))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    if segment.correctionId != nil {
                        Text("Corrected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(EpistoriaDesign.ink.opacity(0.08), in: Capsule())
                    }
                }
                Text(segment.text)
                    .textSelection(.enabled)
                if segment.correctionId != nil, segment.original.text != segment.text {
                    Text("Generated: \(segment.original.text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 4)
            Button {
                openAtTime(segment.original.startSeconds)
            } label: {
                Label("Open media at timestamp", systemImage: "play")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            Button {
                editingSegment = segment
            } label: {
                Label("Correct segment", systemImage: "pencil")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(correctionConflicts.contains { $0.segmentIndex == segment.id })
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { updateSelection(with: segment.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mediaTimeLabel(segment.original.startSeconds)) to \(mediaTimeLabel(segment.original.endSeconds)), \(segment.text)")
        .accessibilityValue(selectedSegmentIndexes.contains(segment.id) ? "Selected" : "Not selected")
        .accessibilityAction(named: "Select for Evidence") { updateSelection(with: segment.id) }
        .accessibilityAction(named: "Open media at timestamp") {
            openAtTime(segment.original.startSeconds)
        }
        .accessibilityAction(named: "Correct transcript") {
            if !correctionConflicts.contains(where: { $0.segmentIndex == segment.id }) {
                editingSegment = segment
            }
        }
    }

    private var selectedRangeLabel: String {
        guard let first = selectedSegments.first, let last = selectedSegments.last else { return "None" }
        return "\(mediaTimeLabel(first.original.startSeconds))–\(mediaTimeLabel(last.original.endSeconds))"
    }

    private func updateSelection(with segmentIndex: Int) {
        guard let position = effectiveSegments.firstIndex(where: { $0.id == segmentIndex }) else { return }
        if selectedSegmentIndexes.count == 1 && selectedSegmentIndexes.contains(segmentIndex) {
            clearSelection()
            return
        }
        guard let anchor = selectionAnchor,
              let anchorPosition = effectiveSegments.firstIndex(where: { $0.id == anchor })
        else {
            selectionAnchor = segmentIndex
            selectedSegmentIndexes = [segmentIndex]
            return
        }
        let range = min(anchorPosition, position)...max(anchorPosition, position)
        selectedSegmentIndexes = Set(range.map { effectiveSegments[$0].id })
    }

    private func clearSelection() {
        selectedSegmentIndexes = []
        selectionAnchor = nil
    }

    private func loadReviewedTranscript() async {
        reviewedManifest = manifest
        reviewedSegments = segments.map {
            ReviewedTranscriptSegment(original: $0, text: $0.text, correctionId: nil)
        }
        guard let store = model.store, let transcriptionArtifactId else { return }
        do {
            let loadedManifest = try await store.payload(
                MediaTranscriptionManifest.self,
                id: transcriptionArtifactId
            )
            let loadedCorrections = try await store.transcriptCorrections(
                transcriptionArtifactId: transcriptionArtifactId
            )
            reviewedManifest = loadedManifest.payload
            corrections = loadedCorrections
            reviewedSegments = try await store.reviewedTranscriptSegments(
                transcriptionArtifactId: transcriptionArtifactId
            )
            errorMessage = nil
        } catch StoreError.transcriptCorrectionConflict {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveCorrection(
        segmentIndex: Int,
        correctedText: String,
        reason: String?
    ) async throws {
        guard let store = model.store, let transcriptionArtifactId else {
            throw StoreError.entityNotFound
        }
        _ = try await store.createTranscriptCorrection(
            transcriptionArtifactId: transcriptionArtifactId,
            segmentIndex: segmentIndex,
            correctedText: correctedText,
            reason: reason
        )
        model.noteLocalMutation()
        statusMessage = "Correction saved. Generated text is preserved."
        await loadReviewedTranscript()
        changed()
    }

    private func retractCorrection(_ correctionId: UUID?) async throws {
        guard let store = model.store, let correctionId else { throw StoreError.entityNotFound }
        try await store.retractTranscriptCorrection(id: correctionId)
        model.noteLocalMutation()
        statusMessage = "Correction retracted. Its history is preserved."
        await loadReviewedTranscript()
        changed()
    }

    private func createEvidence(note: String?) async throws {
        guard let store = model.store, let transcriptionArtifactId else {
            throw StoreError.entityNotFound
        }
        _ = try await store.createTranscriptEvidence(
            transcriptionArtifactId: transcriptionArtifactId,
            segmentIndexes: selectedSegments.map(\ .id),
            note: note
        )
        model.noteLocalMutation()
        statusMessage = "Timestamped Evidence created."
        clearSelection()
        changed()
    }

    private func resolveCorrectionConflict(segmentIndex: Int, keeping correctionId: UUID?) async {
        guard let store = model.store, let transcriptionArtifactId else { return }
        do {
            try await store.resolveTranscriptCorrectionConflict(
                transcriptionArtifactId: transcriptionArtifactId,
                segmentIndex: segmentIndex,
                keeping: correctionId
            )
            model.noteLocalMutation()
            statusMessage = correctionId == nil
                ? "Conflict resolved with generated text. Correction history is preserved."
                : "Correction conflict resolved. Other candidates remain in history."
            await loadReviewedTranscript()
            changed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func conflictTimeLabel(_ segmentIndex: Int) -> String {
        guard let segment = segments.first(where: { $0.index == segmentIndex }) else {
            return "Segment \(segmentIndex + 1)"
        }
        return "\(mediaTimeLabel(segment.startSeconds))–\(mediaTimeLabel(segment.endSeconds))"
    }
}

private struct TranscriptCorrectionConflictGroup: Identifiable {
    var segmentIndex: Int
    var candidates: [IdentifiedPayload<TranscriptCorrectionPayload>]
    var id: Int { segmentIndex }
}

private struct TranscriptCorrectionEditor: View {
    let segment: ReviewedTranscriptSegment
    let history: [IdentifiedPayload<TranscriptCorrectionPayload>]
    let save: (String, String?) async throws -> Void
    let retract: (() async throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var correctedText: String
    @State private var reason: String
    @State private var isSaving = false
    @State private var isConfirmingRetraction = false
    @State private var errorMessage: String?

    init(
        segment: ReviewedTranscriptSegment,
        history: [IdentifiedPayload<TranscriptCorrectionPayload>],
        save: @escaping (String, String?) async throws -> Void,
        retract: (() async throws -> Void)?
    ) {
        self.segment = segment
        self.history = history
        self.save = save
        self.retract = retract
        _correctedText = State(initialValue: segment.text)
        _reason = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Generated text") {
                    Text(segment.original.text).textSelection(.enabled)
                }
                Section {
                    TextEditor(text: $correctedText)
                        .frame(minHeight: 120)
                    TextField("Reason (optional)", text: $reason, axis: .vertical)
                } header: {
                    Text("Your correction")
                } footer: {
                    Text("Saving creates a new encrypted correction record. It does not replace the generated transcript.")
                }
                if !history.isEmpty {
                    Section("Correction history") {
                        ForEach(history, id: \ .id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.payload.state.rawValue.capitalized)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(item.payload.createdAt, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.payload.correctedText)
                                if let reason = item.payload.reason {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if retract != nil {
                    Section {
                        Button("Use generated text", systemImage: "arrow.uturn.backward") {
                            isConfirmingRetraction = true
                        }
                    } footer: {
                        Text("The correction stays in history but no longer changes the effective transcript.")
                    }
                }
            }
            .navigationTitle("Correct transcript")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await performSave() } }
                        .fontWeight(.semibold)
                        .disabled(
                            correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || correctedText.trimmingCharacters(in: .whitespacesAndNewlines) == segment.text
                        )
                }
            }
        }
        .confirmationDialog(
            "Use the generated text for this segment?",
            isPresented: $isConfirmingRetraction,
            titleVisibility: .visible
        ) {
            Button("Retract correction") { Task { await performRetraction() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Correction history is retained.")
        }
        .alert("Correction problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func performSave() async {
        isSaving = true
        do {
            let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            try await save(correctedText, cleanReason.isEmpty ? nil : cleanReason)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func performRetraction() async {
        guard let retract else { return }
        isSaving = true
        do {
            try await retract()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private struct TranscriptEvidenceEditor: View {
    let title: String
    let segments: [ReviewedTranscriptSegment]
    let create: (String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Timestamp") {
                    LabeledContent("Source", value: title)
                    if let first = segments.first, let last = segments.last {
                        LabeledContent(
                            "Range",
                            value: "\(mediaTimeLabel(first.original.startSeconds))–\(mediaTimeLabel(last.original.endSeconds))"
                        )
                    }
                }
                Section {
                    Text(segments.map(\ .text).joined(separator: " "))
                        .textSelection(.enabled)
                } header: {
                    Text("Frozen excerpt")
                } footer: {
                    Text("Evidence keeps this reviewed text, the exact Source Version, segment indexes, timestamps, and applied correction records.")
                }
                Section("Note") {
                    TextField("Optional context", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Create Evidence")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Creating…" : "Create") { Task { await performCreate() } }
                        .fontWeight(.semibold)
                        .disabled(segments.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("Evidence problem", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func performCreate() async {
        isSaving = true
        do {
            let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try await create(cleanNote.isEmpty ? nil : cleanNote)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private func mediaTimeLabel(_ time: TimeInterval) -> String {
    guard time.isFinite, time >= 0 else { return "0:00" }
    let total = Int(time.rounded(.down))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
    return String(format: "%d:%02d", minutes, seconds)
}

private struct SourceComparisonView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let initialSourceId: UUID

    @State private var sources: [IdentifiedPayload<SourcePayload>] = []
    @State private var versionsBySource: [UUID: [IdentifiedPayload<SourceVersionPayload>]] = [:]
    @State private var leftSourceId: UUID
    @State private var rightSourceId: UUID
    @State private var leftVersionId: UUID?
    @State private var rightVersionId: UUID?
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(model: AppModel, initialSourceId: UUID) {
        self.model = model
        self.initialSourceId = initialSourceId
        _leftSourceId = State(initialValue: initialSourceId)
        _rightSourceId = State(initialValue: initialSourceId)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Preparing comparison…")
                } else if sources.isEmpty {
                    ContentUnavailableView("No Sources", systemImage: "rectangle.split.2x1")
                } else {
                    GeometryReader { proxy in
                        if proxy.size.width >= 820 {
                            HStack(spacing: 0) {
                                comparisonPane(sourceId: leftSourceId, versionId: $leftVersionId)
                                Divider()
                                comparisonPane(sourceId: rightSourceId, versionId: $rightVersionId)
                            }
                        } else {
                            ScrollView {
                                VStack(spacing: 12) {
                                    comparisonPane(sourceId: leftSourceId, versionId: $leftVersionId)
                                        .frame(minHeight: 520)
                                    Divider()
                                    comparisonPane(sourceId: rightSourceId, versionId: $rightVersionId)
                                        .frame(minHeight: 520)
                                }
                                .padding(.horizontal, 12)
                            }
                        }
                    }
                }
            }
            .epistoriaPageBackground()
            .navigationTitle("Compare Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .principal) {
                    sourcePicker(title: "Left", selection: sourceBinding(isLeft: true))
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    sourcePicker(title: "Right", selection: sourceBinding(isLeft: false))
                }
            }
            .task { await load() }
            .alert("Comparison error", isPresented: .constant(errorMessage != nil)) {
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func comparisonPane(sourceId: UUID, versionId: Binding<UUID?>) -> some View {
        if let source = sources.first(where: { $0.id == sourceId }) {
            SourceComparisonPane(
                model: model,
                source: source,
                versions: versionsBySource[sourceId] ?? [],
                selectedVersionId: versionId
            )
        } else {
            ContentUnavailableView("Source unavailable", systemImage: "doc.questionmark")
        }
    }

    private func sourcePicker(title: String, selection: Binding<UUID>) -> some View {
        Picker(title, selection: selection) {
            ForEach(sources, id: \.id) { source in
                Text(source.payload.title).tag(source.id)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("\(title) Source")
    }

    private func sourceBinding(isLeft: Bool) -> Binding<UUID> {
        Binding(
            get: { isLeft ? leftSourceId : rightSourceId },
            set: { id in
                if isLeft {
                    leftSourceId = id
                    leftVersionId = currentVersionId(for: id)
                } else {
                    rightSourceId = id
                    rightVersionId = currentVersionId(for: id)
                }
            }
        )
    }

    private func currentVersionId(for sourceId: UUID) -> UUID? {
        sources.first { $0.id == sourceId }?.payload.currentVersionId
            ?? versionsBySource[sourceId]?.first?.id
    }

    private func load() async {
        guard let store = model.store else { return }
        isLoading = true
        do {
            let loadedSources = try await store.list(SourcePayload.self)
                .filter { $0.payload.archivedAt == nil }
                .sorted { $0.payload.title.localizedCaseInsensitiveCompare($1.payload.title) == .orderedAscending }
            var loadedVersions: [UUID: [IdentifiedPayload<SourceVersionPayload>]] = [:]
            for source in loadedSources {
                loadedVersions[source.id] = try await store.list(SourceVersionPayload.self, parentId: source.id)
                    .sorted { $0.payload.versionNumber > $1.payload.versionNumber }
            }
            sources = loadedSources
            versionsBySource = loadedVersions
            guard let initial = loadedSources.first(where: { $0.id == initialSourceId }) ?? loadedSources.first else {
                isLoading = false
                return
            }
            leftSourceId = initial.id
            leftVersionId = initial.payload.currentVersionId ?? loadedVersions[initial.id]?.first?.id
            if let prior = loadedVersions[initial.id]?.first(where: { $0.id != leftVersionId }) {
                rightSourceId = initial.id
                rightVersionId = prior.id
            } else if let other = loadedSources.first(where: { $0.id != initial.id }) {
                rightSourceId = other.id
                rightVersionId = other.payload.currentVersionId ?? loadedVersions[other.id]?.first?.id
            } else {
                rightSourceId = initial.id
                rightVersionId = leftVersionId
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct SourceComparisonPane: View {
    @Bindable var model: AppModel
    let source: IdentifiedPayload<SourcePayload>
    let versions: [IdentifiedPayload<SourceVersionPayload>]
    @Binding var selectedVersionId: UUID?

    @State private var data: Data?
    @State private var csv: CSVSourceDocument?
    @State private var text: String?
    @State private var filenameExtension = "mp4"
    @State private var pageNumber = 1
    @State private var pageCount = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.payload.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(source.payload.sourceType.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !versions.isEmpty {
                    Picker("Version", selection: $selectedVersionId) {
                        ForEach(versions, id: \.id) { version in
                            Text(versionLabel(version)).tag(Optional(version.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Version of \(source.payload.title)")
                }
            }
            .padding(12)
            .background(.thinMaterial)

            Divider()

            Group {
                if isLoading {
                    ProgressView("Decrypting locally…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Source unavailable", systemImage: "doc.questionmark")
                    } description: {
                        Text(errorMessage)
                    }
                } else if source.payload.sourceType == .youtube, let url = selectedURL {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("YouTube reference", systemImage: "play.rectangle")
                                .font(.headline)
                            Text(url.absoluteString).textSelection(.enabled)
                            Text("Comparison does not load the online player. The saved reference remains unchanged.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                    }
                } else if let data, source.payload.sourceType == .pdf {
                    PDFDocumentView(
                        data: data,
                        pageNumber: $pageNumber,
                        pageCount: $pageCount,
                        highlightText: nil
                    )
                } else if let data, source.payload.sourceType == .image,
                          let image = UIImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit().padding(20)
                    }
                } else if let data, source.payload.sourceType == .audio {
                    AudioSourceView(data: data)
                } else if let data, source.payload.sourceType == .video {
                    VideoSourceView(data: data, filenameExtension: filenameExtension)
                } else if let csv {
                    CSVSourceView(document: csv)
                } else if let text {
                    StructuredSourceTextView(
                        text: text,
                        usesMonospacedText: source.payload.sourceType == .markdown
                    )
                } else {
                    ContentUnavailableView {
                        Label("No readable local copy", systemImage: "doc.questionmark")
                    } description: {
                        Text("This exact Source Version is not available on this device.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(EpistoriaDesign.canvas)
        .task(id: taskIdentity) { await load() }
        .onChange(of: selectedVersionId) {
            pageNumber = 1
        }
    }

    private var selectedVersion: IdentifiedPayload<SourceVersionPayload>? {
        versions.first { $0.id == selectedVersionId }
            ?? versions.first { $0.id == source.payload.currentVersionId }
            ?? versions.first
    }

    private var selectedURL: URL? {
        selectedVersion?.payload.capturedURL ?? source.payload.canonicalURL
    }

    private var taskIdentity: String {
        "\(source.id.uuidString):\(selectedVersionId?.uuidString ?? "original")"
    }

    private func versionLabel(_ version: IdentifiedPayload<SourceVersionPayload>) -> String {
        let suffix = version.id == source.payload.currentVersionId ? " · Current" : ""
        return "Version \(version.payload.versionNumber)\(suffix)"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        data = nil
        csv = nil
        text = nil
        guard source.payload.sourceType != .youtube else {
            isLoading = false
            return
        }
        guard let assetManager = model.assetManager else {
            errorMessage = "The local asset store is unavailable."
            isLoading = false
            return
        }
        let assetId = selectedVersion?.payload.originalAssetId ?? source.payload.originalAssetId
        guard let assetId else {
            isLoading = false
            return
        }
        do {
            if let store = model.store,
               let asset = try? await store.payload(AssetPayload.self, id: assetId).payload {
                let ext = URL(fileURLWithPath: asset.originalFilename).pathExtension.lowercased()
                if ["m4v", "mov", "mp4"].contains(ext) { filenameExtension = ext }
            }
            let decrypted = try await assetManager.decryptedLocalData(assetId: assetId)
            data = decrypted
            let prepared = try await SourceDetailView.prepareReaderContent(
                data: decrypted,
                sourceType: source.payload.sourceType
            )
            csv = prepared.csv
            text = prepared.text
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct PreparedSourceContent: Sendable {
    var csv: CSVSourceDocument?
    var text: String?

    init(csv: CSVSourceDocument? = nil, text: String? = nil) {
        self.csv = csv
        self.text = text
    }
}

private struct SharedWebReferenceView: View {
    let url: URL
    let capture: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Shared webpage", systemImage: "link")
        } description: {
            VStack(spacing: 8) {
                Text(url.absoluteString)
                    .textSelection(.enabled)
                Text("The link was saved without contacting the website.")
            }
        } actions: {
            Button("Capture offline copy", action: capture)
                .buttonStyle(.borderedProminent)
                .tint(EpistoriaDesign.ink)
        }
    }
}

private struct WebSnapshotChangesView: View {
    let difference: WebSnapshotDifference
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !difference.previousVersionAvailable {
                        Label("Previous version unavailable for comparison", systemImage: "questionmark.circle")
                    } else if difference.isUnchanged {
                        Label("No readable text changed", systemImage: "equal.circle")
                    } else {
                        LabeledContent("Added paragraphs", value: difference.addedParagraphCount.formatted())
                        LabeledContent("Removed paragraphs", value: difference.removedParagraphCount.formatted())
                    }
                } footer: {
                    Text("The previous snapshot remains available to citations and learning records that already reference it.")
                }

                if !difference.addedExamples.isEmpty {
                    Section("Added examples") {
                        ForEach(difference.addedExamples, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
                if !difference.removedExamples.isEmpty {
                    Section("Removed examples") {
                        ForEach(difference.removedExamples, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AudioSourceView: View {
    let data: Data
    var initialTime: TimeInterval? = nil

    @State private var player: AVAudioPlayer?
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var isPlaying = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { min(currentTime, max(duration, 0)) },
                        set: { seek(to: $0) }
                    ),
                    in: 0...max(duration, 1)
                )
                .disabled(player == nil)
                .accessibilityLabel("Recording position")
                .accessibilityValue("\(timeLabel(currentTime)) of \(timeLabel(duration))")

                HStack {
                    Text(timeLabel(currentTime))
                    Spacer()
                    Text("−\(timeLabel(max(duration - currentTime, 0)))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 34) {
                Button { skip(by: -15) } label: {
                    Label("Back 15 seconds", systemImage: "gobackward.15")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .disabled(player == nil)

                Button { togglePlayback() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 62, height: 62)
                        .background(EpistoriaDesign.ink, in: Circle())
                        .foregroundStyle(EpistoriaDesign.inverseInk)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(player == nil)
                .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")

                Button { skip(by: 15) } label: {
                    Label("Forward 15 seconds", systemImage: "goforward.15")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .disabled(player == nil)
            }
            .foregroundStyle(.primary)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Playback stays on this iPad.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(EpistoriaDesign.Spacing.page)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { prepare() }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled, let player, player.isPlaying {
                currentTime = player.currentTime
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !Task.isCancelled {
                currentTime = player?.currentTime ?? currentTime
                isPlaying = false
            }
        }
        .onDisappear { stop() }
    }

    private func prepare() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let created = try AVAudioPlayer(data: data)
            guard created.prepareToPlay(), created.duration.isFinite, created.duration > 0 else {
                throw SourceAdapterError.malformed
            }
            player = created
            duration = created.duration
            let requested = initialTime.flatMap { $0.isFinite ? $0 : nil } ?? 0
            created.currentTime = min(max(requested, 0), created.duration)
            currentTime = created.currentTime
        } catch {
            errorMessage = "This recording could not be decoded on this iPad."
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            currentTime = player.currentTime
            isPlaying = false
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.play()
            currentTime = player.currentTime
            isPlaying = player.isPlaying
        }
    }

    private func seek(to value: Double) {
        guard let player else { return }
        player.currentTime = min(max(value, 0), player.duration)
        currentTime = player.currentTime
    }

    private func skip(by interval: TimeInterval) {
        seek(to: currentTime + interval)
    }

    private func stop() {
        player?.stop()
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct VideoSourceView: View {
    let data: Data
    let filenameExtension: String
    var initialTime: TimeInterval? = nil

    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .background(Color.black)
                    .accessibilityLabel("Video Source player")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Video unavailable", systemImage: "play.slash")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ProgressView("Preparing protected playback…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: data) { await prepare() }
        .onDisappear { cleanUp() }
    }

    @MainActor
    private func prepare() async {
        guard player == nil, temporaryURL == nil else { return }
        do {
            let bytes = data
            let ext = filenameExtension
            let url = try await Task.detached(priority: .userInitiated) {
                try ProtectedVideoFileStore.write(bytes, filenameExtension: ext)
            }.value
            guard !Task.isCancelled else {
                try? ProtectedVideoFileStore.remove(url)
                return
            }
            temporaryURL = url
            let created = AVPlayer(url: url)
            if let initialTime, initialTime.isFinite, initialTime > 0 {
                await created.seek(
                    to: CMTime(seconds: initialTime, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            player = created
        } catch {
            errorMessage = "Epistoria could not prepare this video for local playback."
        }
    }

    private func cleanUp() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let temporaryURL { try? ProtectedVideoFileStore.remove(temporaryURL) }
        temporaryURL = nil
    }
}

private struct StructuredSourceTextView: View {
    let text: String
    let usesMonospacedText: Bool

    var body: some View {
        ScrollView {
            Text(text)
                .font(usesMonospacedText ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .lineSpacing(4)
                .frame(maxWidth: EpistoriaDesign.Layout.readingWidth, alignment: .leading)
                .padding(EpistoriaDesign.Spacing.page)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityLabel("Readable Source text")
    }
}

private struct CSVSourceView: View {
    let document: CSVSourceDocument

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let header = document.rows.first {
                    Section {
                        ForEach(document.rows.indices.dropFirst(), id: \.self) { index in
                            csvRow(document.rows[index], index: index, isHeader: false)
                        }
                    } header: {
                        csvRow(header, index: 0, isHeader: true)
                    }
                }
            }
            .padding(EpistoriaDesign.Spacing.page)
        }
        .accessibilityLabel("CSV table with \(document.rows.count) rows and \(document.maximumColumnCount) columns")
    }

    private func csvRow(_ row: [String], index: Int, isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            Text(isHeader ? "" : index.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
                .padding(.trailing, 10)
            ForEach(0..<document.maximumColumnCount, id: \.self) { column in
                Text(column < row.count ? row[column] : "")
                    .font(isHeader ? .body.weight(.semibold) : .body)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(width: 190, alignment: .leading)
                    .frame(minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isHeader ? Color.primary.opacity(0.08) : Color.clear)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isHeader ? "Header row" : "Row \(index)")
    }
}

private struct SourceOrganizationView: View {
    @Bindable var model: AppModel
    let source: IdentifiedPayload<SourcePayload>?
    let topics: [IdentifiedPayload<TopicPayload>]
    let lists: [IdentifiedPayload<ListPayload>]
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
        lists: [IdentifiedPayload<ListPayload>],
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
                parentId: payload.sourceId,
                relationIds: [
                    Optional(payload.sourceId),
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
    var highlightRectangles: [AnnotationRectangle] = []

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
            context.coordinator.applyRectangleHighlightsIfNeeded(highlightRectangles)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        // `data` is immutable for the lifetime of this detail view. Re-serializing the
        // PDFDocument here would copy the entire file on routine page/highlight updates.
        context.coordinator.applyHighlightIfNeeded(highlightText)
        context.coordinator.applyRectangleHighlightsIfNeeded(highlightRectangles)
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
        private var lastRectangles: [AnnotationRectangle] = []
        private var lastRectanglePage = 0
        private var transientAnnotations: [(PDFPage, PDFAnnotation)] = []

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

        func applyRectangleHighlightsIfNeeded(_ rectangles: [AnnotationRectangle]) {
            guard rectangles != lastRectangles || parent.pageNumber != lastRectanglePage else {
                return
            }
            lastRectangles = rectangles
            lastRectanglePage = parent.pageNumber
            for (page, annotation) in transientAnnotations {
                page.removeAnnotation(annotation)
            }
            transientAnnotations = []
            guard !rectangles.isEmpty,
                  let view = pdfView,
                  let document = view.document,
                  parent.pageNumber > 0,
                  parent.pageNumber <= document.pageCount,
                  let page = document.page(at: parent.pageNumber - 1)
            else { return }
            let pageBounds = page.bounds(for: .cropBox)
            for rectangle in rectangles {
                let bounds = CGRect(
                    x: pageBounds.minX + rectangle.x * pageBounds.width,
                    y: pageBounds.maxY
                        - (rectangle.y + rectangle.height) * pageBounds.height,
                    width: rectangle.width * pageBounds.width,
                    height: rectangle.height * pageBounds.height
                )
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemGray.withAlphaComponent(0.35)
                page.addAnnotation(annotation)
                transientAnnotations.append((page, annotation))
            }
            view.go(to: CGRect(
                x: pageBounds.minX,
                y: transientAnnotations.first?.1.bounds.midY ?? pageBounds.midY,
                width: pageBounds.width,
                height: 1
            ), on: page)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Opened cited region on PDF page \(parent.pageNumber)"
            )
        }

        private func viewClearHighlights() {
            pdfView?.highlightedSelections = nil
        }
    }

}
