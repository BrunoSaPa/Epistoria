import EpistoriaCore
import SwiftUI
import UniformTypeIdentifiers

private enum TodayDestination: Hashable {
    case note(UUID)
    case session(UUID)
    case resource(UUID)
}

struct TodayView: View {
    @Bindable var model: AppModel

    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var resources: [IdentifiedPayload<ResourcePayload>] = []
    @State private var courses: [IdentifiedPayload<CoursePayload>] = []
    @State private var destination: TodayDestination?
    @State private var showNewSession = false
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var importProgress: String?
    @State private var errorMessage: String?

    private let actionColumns = [GridItem(.adaptive(minimum: 250), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    welcomeHeader
                    syncStatusCard
                    quickActions
                    activeSessionCard
                    recentSection
                }
                .padding(.horizontal, EpistoriaDesign.Spacing.page)
                .padding(.vertical, EpistoriaDesign.Spacing.xLarge)
                .frame(maxWidth: EpistoriaDesign.Layout.pageWidth)
                .frame(maxWidth: .infinity)
            }
            .epistoriaPageBackground()
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.selectedSection = .search
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("today.search")

                    Button {
                        Task {
                            await model.synchronize()
                            await load()
                        }
                    } label: {
                        Label(model.isSyncing ? "Syncing" : "Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isSyncing || model.syncEngine == nil)
                    .accessibilityIdentifier("today.sync")
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: model.isSyncing) { wasSyncing, isSyncing in
                guard wasSyncing, !isSyncing else { return }
                Task { await load() }
            }
            .navigationDestination(item: $destination) { value in
                switch value {
                case let .note(id):
                    NoteEditorView(model: model, noteId: id)
                case let .session(id):
                    SessionDetailView(model: model, sessionId: id)
                case let .resource(id):
                    ResourceDetailView(model: model, resourceId: id)
                }
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionView(model: model, courses: courses) { id in
                    Task {
                        await load()
                        destination = .session(id)
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                Task { await importFiles(result) }
            }
            .safeAreaInset(edge: .bottom) {
                if let importProgress {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(importProgress)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 3)
                    .padding()
                    .accessibilityElement(children: .combine)
                }
            }
            .alert("Today needs attention", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await load() } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(EpistoriaDesign.mutedInk)
            Text(greeting)
                .font(.largeTitle.weight(.bold))
            Text("Choose the next useful action. Everything remains available offline.")
                .font(.body)
                .foregroundStyle(EpistoriaDesign.mutedInk)
        }
        .accessibilityElement(children: .combine)
    }

    private var syncStatusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: syncSymbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(syncTone)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(syncTitle)
                    .font(.subheadline.weight(.semibold))
                Text(syncDetail)
                    .font(.caption)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
            }
            Spacer(minLength: 10)

            if model.configuration?.serverConnected == true {
                Button(model.isSyncing ? "Syncing…" : "Sync now") {
                    Task {
                        await model.synchronize()
                        await load()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isSyncing)
            } else {
                Button("Set up") { model.selectedSection = .dataHealth }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.local-status")
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            EpistoriaSectionHeading(
                title: "Start something",
                subtitle: "Capture a thought, focus your time, or bring in a document."
            )
            LazyVGrid(columns: actionColumns, spacing: 10) {
                EpistoriaQuickAction(
                    title: "Quick note",
                    subtitle: "Open a blank page",
                    symbol: "square.and.pencil",
                    prominent: true
                ) {
                    Task { await createQuickNote() }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("today.quick-note")

                EpistoriaQuickAction(
                    title: activeSession == nil ? "Start a session" : "Continue session",
                    subtitle: activeSession == nil ? "Set an intention" : activeSession?.payload.title ?? "Return to your work",
                    symbol: activeSession == nil ? "play.circle" : "timer"
                ) {
                    if let activeSession {
                        destination = .session(activeSession.id)
                    } else {
                        showNewSession = true
                    }
                }
                .accessibilityIdentifier("today.session")

                EpistoriaQuickAction(
                    title: "Import PDF",
                    subtitle: "Encrypt it on this iPad",
                    symbol: "doc.badge.plus"
                ) {
                    isImporting = true
                }
                .accessibilityIdentifier("today.import-pdf")
            }
        }
    }

    @ViewBuilder
    private var activeSessionCard: some View {
        if let activeSession {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    EpistoriaStatusPill(title: "In progress", symbol: "circle.fill", tone: .positive)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(activeSession.payload.startedAt, style: .timer)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(EpistoriaDesign.accent)
                    }
                }
                Text(activeSession.payload.title)
                    .font(.title2.weight(.bold))
                if let goal = activeSession.payload.goals.first {
                    Label(goal, systemImage: "target")
                        .font(.subheadline)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                }
                Button {
                    destination = .session(activeSession.id)
                } label: {
                    Label("Continue studying", systemImage: "arrow.right")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("today.continue-session")
            }
            .padding(.leading, 18)
            .padding(.vertical, 4)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(EpistoriaDesign.ink)
                    .frame(width: 3)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            EpistoriaSectionHeading(
                title: "Recent",
                subtitle: "Open the notes and resources you touched most recently."
            )

            if notes.isEmpty && resources.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(EpistoriaDesign.mutedInk)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No recent work")
                            .font(.subheadline.weight(.semibold))
                        Text("Create a note or import a PDF; both are encrypted before sync.")
                            .font(.caption)
                            .foregroundStyle(EpistoriaDesign.mutedInk)
                    }
                    Spacer(minLength: 12)
                    Button("New note") { Task { await createQuickNote() } }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                }
                .padding(16)
                .overlay {
                    RoundedRectangle(cornerRadius: EpistoriaDesign.cardRadius, style: .continuous)
                        .stroke(EpistoriaDesign.border.opacity(0.5), lineWidth: 0.5)
                }
                .accessibilityElement(children: .contain)
            } else {
                VStack(spacing: 0) {
                    ForEach(notes.prefix(4), id: \.id) { note in
                        Button {
                            destination = .note(note.id)
                        } label: {
                            recentRow(
                                title: note.payload.title,
                                detail: "Edited \(note.payload.updatedAt.formatted(.relative(presentation: .named)))",
                                symbol: "doc.text",
                                pending: note.syncState != .synced
                            )
                        }
                        .buttonStyle(EpistoriaPressButtonStyle())
                        .accessibilityIdentifier("today.recent-note.\(note.id.uuidString)")
                    }

                    ForEach(resources.prefix(4), id: \.id) { resource in
                        Button {
                            destination = .resource(resource.id)
                        } label: {
                            recentRow(
                                title: resource.payload.title,
                                detail: "Imported \(resource.payload.importedAt.formatted(.relative(presentation: .named)))",
                                symbol: resource.payload.resourceType == .pdf ? "doc.richtext" : "link",
                                pending: resource.syncState != .synced
                            )
                        }
                        .buttonStyle(EpistoriaPressButtonStyle())
                        .accessibilityIdentifier("today.recent-resource.\(resource.id.uuidString)")
                    }
                }
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private func recentRow(title: String, detail: String, symbol: String, pending: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(EpistoriaDesign.mutedInk)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(detail)
                    if pending {
                        Text("· Saved locally")
                    }
                }
                .font(.caption)
                .foregroundStyle(EpistoriaDesign.mutedInk)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 40)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var activeSession: IdentifiedPayload<StudySessionPayload>? {
        sessions.first { $0.payload.state == .active }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var syncTitle: String {
        if model.isSyncing { return "Syncing encrypted changes" }
        if model.syncError != nil { return "Your work is safe on this iPad" }
        if model.configuration?.serverConnected != true { return "Local-first and ready" }
        if model.unresolvedConflictCount > 0 { return "Choose between preserved versions" }
        if model.pendingRecordCount + model.pendingFileCount > 0 {
            return "Saved locally, waiting to sync"
        }
        return "Everything is up to date"
    }

    private var syncDetail: String {
        if model.unresolvedConflictCount > 0 {
            return "\(model.unresolvedConflictCount) version decision\(model.unresolvedConflictCount == 1 ? "" : "s") need your review."
        }
        return model.syncStatusText
    }

    private var syncSymbol: String {
        model.unresolvedConflictCount > 0 ? "arrow.triangle.branch" : model.syncStatusSymbol
    }

    private var syncTone: Color {
        if model.syncError != nil { return EpistoriaDesign.attention }
        if model.unresolvedConflictCount > 0 { return EpistoriaDesign.attention }
        return EpistoriaDesign.positive
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedNotes = store.list(NotePayload.self)
            async let loadedSessions = store.list(StudySessionPayload.self)
            async let loadedResources = store.list(ResourcePayload.self)
            async let loadedCourses = store.list(CoursePayload.self)
            let result = try await (loadedNotes, loadedSessions, loadedResources, loadedCourses)
            notes = result.0
                .filter { $0.payload.archivedAt == nil }
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            sessions = result.1.sorted { $0.payload.startedAt > $1.payload.startedAt }
            resources = result.2.sorted { $0.payload.importedAt > $1.payload.importedAt }
            courses = result.3.filter { !$0.payload.archived }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createQuickNote() async {
        guard let store = model.store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let timestamp = Date.now.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            )
            let id = try await store.createNote(title: "Quick note — \(timestamp)")
            model.noteLocalMutation()
            await load()
            destination = .note(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard let assetManager = model.assetManager else { return }
        do {
            let urls = try result.get()
            var lastResourceId: UUID?
            for (index, url) in urls.enumerated() {
                importProgress = "Encrypting \(index + 1) of \(urls.count): \(url.lastPathComponent)"
                let imported = try await assetManager.importPDF(from: url)
                lastResourceId = imported.resourceId
            }
            model.noteLocalMutation()
            importProgress = nil
            await load()
            if urls.count == 1, let lastResourceId {
                destination = .resource(lastResourceId)
            }
        } catch {
            importProgress = nil
            errorMessage = error.localizedDescription
        }
    }
}
