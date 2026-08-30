import EpistoriaCore
import SwiftUI
import UniformTypeIdentifiers

private enum TodayDestination: Hashable {
    case note(UUID)
    case session(UUID)
    case resource(UUID)
    case dailyReview
}

struct TodayView: View {
    @Bindable var model: AppModel

    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var resources: [IdentifiedPayload<ResourcePayload>] = []
    @State private var courses: [IdentifiedPayload<CoursePayload>] = []
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var sourceInboxCount = 0
    @State private var cards: [IdentifiedPayload<FlashcardPayload>] = []
    @State private var reviews: [IdentifiedPayload<FlashcardReviewPayload>] = []
    @State private var tests: [IdentifiedPayload<PracticeTestPayload>] = []
    @State private var attempts: [IdentifiedPayload<TestAttemptPayload>] = []
    @State private var goals: [IdentifiedPayload<StudyGoalPayload>] = []
    @State private var unresolved: [IdentifiedPayload<UnresolvedQuestionPayload>] = []
    @State private var recommendations: [IdentifiedPayload<StudyRecommendationPayload>] = []
    @State private var dailyReviewDueCount = 0
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
                    if hasLearningActivity { learningOverview }
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
                case .dailyReview:
                    DailyEvidenceReviewView(model: model)
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
                allowedContentTypes: EpistoriaSourceImportTypes.supported,
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
                Button("Set up") { model.selectedSection = .settings }
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
                    subtitle: "Capture now · organize later",
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
                    title: "Add Source",
                    subtitle: "PDF, image, text, Markdown, or HTML",
                    symbol: "doc.badge.plus"
                ) {
                    isImporting = true
                }
                .accessibilityIdentifier("today.import-pdf")

                EpistoriaQuickAction(
                    title: "Learn",
                    subtitle: "Sessions, review, Tutor, and history",
                    symbol: "graduationcap"
                ) {
                    model.learningLaunchContext = LearningLaunchContext(destination: .overview)
                    model.selectedSection = .learning
                }
                .accessibilityIdentifier("today.learn")
            }
        }
    }

    private var learningOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            EpistoriaSectionHeading(title: "Study Next", subtitle: "A local recommendation based on your saved learning history.")
            if let nextRecommendation {
                Button {
                    model.learningLaunchContext = LearningLaunchContext(destination: .overview)
                    model.selectedSection = .learning
                } label: {
                    recentRow(
                        title: nextRecommendation.title,
                        detail: nextRecommendation.explanation,
                        symbol: nextRecommendation.symbol,
                        pending: false
                    )
                }
                .buttonStyle(EpistoriaPressButtonStyle())
            }
            HStack(spacing: 18) {
                Button("\(dueCards.count) due") {
                    model.learningLaunchContext = LearningLaunchContext(destination: .review)
                    model.selectedSection = .learning
                }
                Button("\(unfinishedAttempts.count) unfinished test\(unfinishedAttempts.count == 1 ? "" : "s")") {
                    model.learningLaunchContext = LearningLaunchContext(destination: .review)
                    model.selectedSection = .learning
                }
                if dailyReviewDueCount > 0 {
                    Button("\(dailyReviewDueCount) daily review") {
                        destination = .dailyReview
                    }
                }
                Button("\(sourceInboxCount) in Source Inbox") { model.selectedSection = .library }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.plain)
        }
    }

    private var hasLearningActivity: Bool {
        nextRecommendation != nil || !dueCards.isEmpty || !unfinishedAttempts.isEmpty
            || dailyReviewDueCount > 0
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
                            NoteReviewPreview(
                                model: model,
                                note: note,
                                context: "Edited \(note.payload.updatedAt.formatted(.relative(presentation: .named)))"
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
                                symbol: resource.payload.resourceType.epistoriaSymbol,
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
        sessions.first { $0.payload.state == .active || $0.payload.state == .paused }
    }

    private var dueCards: [IdentifiedPayload<FlashcardPayload>] {
        cards.filter { card in
            guard card.payload.archivedAt == nil, card.payload.suspendedAt == nil else { return false }
            let latest = reviews.filter { $0.payload.cardId == card.id }.max { $0.payload.reviewedAt < $1.payload.reviewedAt }
            return (latest?.payload.resultingState.dueAt ?? card.payload.createdAt) <= .now
        }
    }

    private var unfinishedAttempts: [IdentifiedPayload<TestAttemptPayload>] {
        attempts.filter { $0.payload.state == .inProgress }
    }

    private var nextRecommendation: LocalStudyRecommendation? {
        StudyNextEngine.rank(
            topics: topics,
            goals: goals,
            unresolvedQuestions: unresolved,
            sessions: sessions,
            tests: tests,
            attempts: attempts,
            dueCardCounts: Dictionary(grouping: dueCards, by: \.payload.topicId).mapValues(\.count),
            learningPlanProjections: learningPlanProjections,
            storedRecommendations: recommendations,
            now: .now
        ).first
    }

    private var learningPlanProjections: [UUID: LearningPlanProjection] {
        Dictionary(uniqueKeysWithValues: goals.compactMap { goal in
            LearningPlanEngine.project(
                goalId: goal.id,
                goal: goal.payload,
                attempts: attempts,
                now: .now
            ).map { (goal.id, $0) }
        })
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
            async let loadedTopics = store.topics()
            async let loadedSources = store.list(SourcePayload.self)
            async let loadedCards = store.list(FlashcardPayload.self)
            async let loadedReviews = store.list(FlashcardReviewPayload.self)
            async let loadedTests = store.list(PracticeTestPayload.self)
            async let loadedAttempts = store.list(TestAttemptPayload.self)
            async let loadedGoals = store.list(StudyGoalPayload.self)
            async let loadedUnresolved = store.list(UnresolvedQuestionPayload.self)
            async let loadedRecommendations = store.list(StudyRecommendationPayload.self)
            async let loadedTrash = store.trashedTargetIds()
            async let loadedDailyReview = store.dailyEvidenceReviewQueue(now: .now)
            let result = try await (loadedNotes, loadedSessions, loadedResources, loadedCourses, loadedTopics, loadedSources, loadedCards, loadedReviews, loadedTests, loadedAttempts, loadedGoals, loadedUnresolved, loadedRecommendations, loadedTrash, loadedDailyReview)
            notes = result.0
                .filter { $0.payload.archivedAt == nil && !result.13.contains($0.id) }
                .sorted {
                    if ($0.payload.pinnedAt != nil) != ($1.payload.pinnedAt != nil) {
                        return $0.payload.pinnedAt != nil
                    }
                    return ($0.payload.pinnedAt ?? $0.payload.updatedAt)
                        > ($1.payload.pinnedAt ?? $1.payload.updatedAt)
                }
            sessions = result.1.sorted { $0.payload.startedAt > $1.payload.startedAt }
            resources = result.2.sorted { $0.payload.importedAt > $1.payload.importedAt }
            courses = result.3.filter { !$0.payload.archived }
            topics = result.4
            sourceInboxCount = result.5.filter {
                $0.payload.primaryTopicId == nil
                    && $0.payload.archivedAt == nil
                    && !result.13.contains($0.id)
            }.count
            cards = result.6
            reviews = result.7
            tests = result.8
            attempts = result.9
            goals = result.10
            unresolved = result.11
            recommendations = result.12
            dailyReviewDueCount = result.14.totalDueCount
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
            let id = try await store.createNote(
                title: "Quick note — \(timestamp)",
                canvas: NoteCanvasConfiguration(
                    pageFormat: model.workspacePreferences.defaultPageFormat,
                    orientation: model.workspacePreferences.defaultPageOrientation,
                    paperStyle: model.workspacePreferences.defaultPaperStyle,
                    paperColor: model.workspacePreferences.defaultPaperColor
                )
            )
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
                let imported = try await assetManager.importSource(from: url)
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
