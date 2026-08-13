import EpistoriaCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionsView: View {
    @Bindable var model: AppModel
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var courses: [IdentifiedPayload<CoursePayload>] = []
    @State private var showNewSession = false
    @State private var createdSessionId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No study sessions yet", systemImage: "timer")
                    } description: {
                        Text("Sessions bind goals, notes, readings, annotations, and an optional cited digest.")
                    } actions: {
                        Button("Start your first session") { showNewSession = true }
                            .buttonStyle(.borderedProminent)
                            .tint(EpistoriaDesign.ink)
                    }
                } else {
                    List {
                        let active = sessions.filter { $0.payload.state == .active }
                        let ended = sessions.filter { $0.payload.state == .ended }
                        if !active.isEmpty {
                            Section("In progress") { sessionRows(active) }
                        }
                        if !ended.isEmpty {
                            Section("History") { sessionRows(ended) }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .epistoriaPageBackground()
            .toolbar {
                Button { showNewSession = true } label: {
                    Label("Start session", systemImage: "play.circle")
                }
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionView(model: model, courses: courses) { id in
                    Task {
                        await load()
                        createdSessionId = id
                    }
                }
            }
            .navigationDestination(item: $createdSessionId) { id in
                SessionDetailView(model: model, sessionId: id)
            }
            .task { await load() }
            .refreshable { await load() }
            .alert("Session error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder
    private func sessionRows(_ values: [IdentifiedPayload<StudySessionPayload>]) -> some View {
        ForEach(values, id: \.id) { session in
            NavigationLink {
                SessionDetailView(model: model, sessionId: session.id)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(session.payload.title).font(.headline)
                        Spacer()
                        if session.payload.state == .active {
                            Label("Live", systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(EpistoriaDesign.positive)
                        }
                    }
                    Text(session.payload.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !session.payload.goals.isEmpty {
                        Text(session.payload.goals.joined(separator: " · "))
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 3)
            }
            .accessibilityIdentifier("sessions.session.\(session.id.uuidString)")
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedSessions = store.list(StudySessionPayload.self)
            async let loadedCourses = store.list(CoursePayload.self)
            let result = try await (loadedSessions, loadedCourses)
            sessions = result.0.sorted { $0.payload.startedAt > $1.payload.startedAt }
            courses = result.1.filter { !$0.payload.archived }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct NewSessionView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let courses: [IdentifiedPayload<CoursePayload>]
    let fixedCourseId: UUID?
    let onCreated: (UUID) -> Void

    @State private var title = ""
    @State private var goals = ""
    @State private var courseId: UUID?
    @State private var errorMessage: String?

    init(
        model: AppModel,
        courses: [IdentifiedPayload<CoursePayload>],
        fixedCourseId: UUID? = nil,
        onCreated: @escaping (UUID) -> Void
    ) {
        self.model = model
        self.courses = courses
        self.fixedCourseId = fixedCourseId
        self.onCreated = onCreated
        _courseId = State(initialValue: fixedCourseId)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("What are you studying?", text: $title)
                if let fixedCourseId,
                   let course = courses.first(where: { $0.id == fixedCourseId })
                {
                    LabeledContent("Course", value: course.payload.name)
                } else {
                    Picker("Course", selection: $courseId) {
                        Text("No course").tag(UUID?.none)
                        ForEach(courses, id: \.id) { course in
                            Text(course.payload.name).tag(Optional(course.id))
                        }
                    }
                }
                Section("Goals") {
                    TextEditor(text: $goals)
                        .frame(minHeight: 120)
                    Text("One goal per line. Keeping goals explicit makes the final digest more useful.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Start a session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await create() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            let parsedGoals = goals
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let id = try await store.startSession(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                courseId: courseId,
                goals: parsedGoals
            )
            model.noteLocalMutation()
            onCreated(id)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SessionDetailView: View {
    @Bindable var model: AppModel
    let sessionId: UUID

    @State private var session: IdentifiedPayload<StudySessionPayload>?
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var resources: [IdentifiedPayload<ResourcePayload>] = []
    @State private var digestArtifact: IdentifiedPayload<SessionDigestArtifact>?
    @State private var preparedDigest: PreparedDigestRequest?
    @State private var submittedJob: AIJobSummary?
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var showDisclosure = false
    @State private var showDigestEditor = false
    @State private var createdNoteId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let session {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(session.payload.title).font(.title2.bold())
                            Spacer()
                            stateBadge(session.payload.state)
                        }
                        if session.payload.state == .active {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(session.payload.startedAt, style: .timer)
                                    .font(.title.monospacedDigit())
                            }
                        } else if let ended = session.payload.endedAt {
                            Text("\(session.payload.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(ended.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if !session.payload.goals.isEmpty {
                    Section("Goals") {
                        ForEach(session.payload.goals, id: \.self) { goal in
                            Label(goal, systemImage: "target")
                        }
                    }
                }

                Section("Notes") {
                    ForEach(notes, id: \.id) { note in
                        NavigationLink(note.payload.title) {
                            NoteEditorView(model: model, noteId: note.id)
                        }
                    }
                    Button("New session note", systemImage: "square.and.pencil") {
                        Task { await createNote() }
                    }
                }

                Section("Resources") {
                    ForEach(resources, id: \.id) { resource in
                        NavigationLink(resource.payload.title) {
                            ResourceDetailView(model: model, resourceId: resource.id, sessionId: sessionId)
                        }
                    }
                    Button("Import PDF for this session", systemImage: "doc.badge.plus") {
                        isImporting = true
                    }
                }

                if session.payload.state == .active {
                    Section {
                        Button("End session", systemImage: "stop.circle", role: .destructive) {
                            Task { await endSession() }
                        }
                    } footer: {
                        Text("Ending freezes the elapsed time. Your notes remain editable.")
                    }
                } else {
                    digestSection
                }
            } else {
                ProgressView("Opening session…")
            }
        }
        .navigationTitle("Study session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                Task {
                    await model.synchronize()
                    await load()
                }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isSyncing || model.syncEngine == nil)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
            Task { await importPDF(result) }
        }
        .navigationDestination(item: $createdNoteId) { id in
            NoteEditorView(
                model: model,
                noteId: id,
                onLifecycleChanged: { Task { await load() } }
            )
        }
        .sheet(isPresented: $showDisclosure) { disclosureSheet }
        .sheet(isPresented: $showDigestEditor) {
            if let digestArtifact {
                DigestEditorView(artifact: digestArtifact.payload) { edited in
                    Task { await review(.edited, editedDigest: edited) }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("Session error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private var digestSection: some View {
        Section("AI session digest") {
            if let artifact = digestArtifact?.payload {
                DigestArtifactView(model: model, artifact: artifact)
                HStack {
                    Button("Accept", systemImage: "checkmark.circle") {
                        Task { await review(.accepted) }
                    }
                    .disabled(artifact.reviewState == .accepted)
                    Button("Edit", systemImage: "pencil") { showDigestEditor = true }
                    Button("Reject", systemImage: "xmark.circle", role: .destructive) {
                        Task { await review(.rejected) }
                    }
                    .disabled(artifact.reviewState == .rejected)
                }
            } else if let submittedJob {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Job \(submittedJob.status.lowercased())", systemImage: "desktopcomputer")
                    Text("The encrypted request waits for your paired Mac. Sync after the worker finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(submittedJob.id.uuidString.lowercased())
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                Button("Prepare cited digest", systemImage: "sparkles") {
                    Task { await prepareDigest() }
                }
                .disabled(isWorking)
                Text("Epistoria first shows exactly which decrypted excerpts will be sent from your Mac. No request is automatic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var disclosureSheet: some View {
        NavigationStack {
            Form {
                if let preview = preparedDigest?.preview {
                    Section("What leaves your Mac") {
                        LabeledContent("Sources", value: "\(preview.sourceCount)")
                        LabeledContent("Characters", value: preview.characterCount.formatted())
                        LabeledContent("Approximate tokens", value: preview.approximateTokens.formatted())
                    }
                    Section("Source titles") {
                        ForEach(preview.sourceTitles, id: \.self) { Text($0) }
                    }
                    Section {
                        Label("Sent only after you approve", systemImage: "hand.raised")
                        Text("The paired Mac decrypts these excerpts and sends them to the configured AI provider. The sync server cannot read them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Digest disclosure")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showDisclosure = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve and queue") { Task { await submitDigest() } }
                        .disabled(preparedDigest == nil || isWorking)
                }
            }
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: StudySessionState) -> some View {
        if state == .active {
            Label("Active", systemImage: "circle.fill")
                .font(.caption.bold())
                .foregroundStyle(EpistoriaDesign.positive)
        } else {
            Label("Ended", systemImage: "checkmark.circle")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            let loadedSession = try await store.payload(StudySessionPayload.self, id: sessionId)
            let allNotes = try await store.list(NotePayload.self)
            let relations = try await store.list(
                RelationPayload.self,
                parentId: sessionId,
                entityTypeOverride: .sessionResource
            )
            var linkedResources: [IdentifiedPayload<ResourcePayload>] = []
            for relation in relations where relation.payload.leftId == sessionId {
                if let resource = try? await store.payload(ResourcePayload.self, id: relation.payload.rightId) {
                    linkedResources.append(resource)
                }
            }
            session = loadedSession
            notes = allNotes.filter {
                $0.payload.studySessionId == sessionId && $0.payload.archivedAt == nil
            }
            resources = linkedResources
            digestArtifact = try await model.aiJobs?.latestDigest(sessionId: sessionId)
        } catch { errorMessage = error.localizedDescription }
    }

    private func createNote() async {
        guard let store = model.store, let session else { return }
        do {
            let id = try await store.createNote(
                title: "Notes — \(session.payload.title)",
                courseId: session.payload.courseId,
                sessionId: sessionId
            )
            model.noteLocalMutation()
            await load()
            createdNoteId = id
        } catch { errorMessage = error.localizedDescription }
    }

    private func importPDF(_ result: Result<URL, Error>) async {
        guard let manager = model.assetManager else { return }
        do {
            let url = try result.get()
            _ = try await manager.importPDF(
                from: url,
                courseId: session?.payload.courseId,
                sessionId: sessionId
            )
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func endSession() async {
        guard let store = model.store else { return }
        do {
            try await store.endSession(id: sessionId)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func prepareDigest() async {
        guard let coordinator = model.aiJobs else {
            errorMessage = "Connect the private server and pair your Mac in Data Health first."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            preparedDigest = try await coordinator.prepareSessionDigest(sessionId: sessionId)
            showDisclosure = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func submitDigest() async {
        guard let coordinator = model.aiJobs, let preparedDigest else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            submittedJob = try await coordinator.submitSessionDigest(preparedDigest)
            self.preparedDigest = nil
            showDisclosure = false
        } catch { errorMessage = error.localizedDescription }
    }

    private func review(_ state: AIArtifactReviewState, editedDigest: SessionDigest? = nil) async {
        guard let store = model.store, var artifact = digestArtifact else { return }
        artifact.payload.reviewState = state
        artifact.payload.reviewedAt = .now
        if let editedDigest { artifact.payload.editedDigest = editedDigest }
        do {
            _ = try await store.save(
                id: artifact.id,
                payload: artifact.payload,
                parentId: sessionId,
                relationIds: [sessionId] + artifact.payload.sourceIds
            )
            model.noteLocalMutation()
            digestArtifact = artifact
            showDigestEditor = false
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct DigestArtifactView: View {
    @Bindable var model: AppModel
    let artifact: SessionDigestArtifact

    private var digest: SessionDigest { artifact.editedDigest ?? artifact.digest }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(digest.title).font(.title3.bold())
                Spacer()
                if let state = artifact.reviewState {
                    Text(state.rawValue.capitalized)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                } else {
                    Text("Needs review")
                        .font(.caption.bold())
                        .foregroundStyle(EpistoriaDesign.attention)
                }
            }
            Text(digest.summary)
            if !digest.keyPoints.isEmpty {
                Text("Key points").font(.headline)
                ForEach(digest.keyPoints) { point in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("• \(point.text)")
                        DigestCitationLinks(model: model, sourceIds: point.sourceIds)
                    }
                }
            }
            if !digest.possibleMisconceptions.isEmpty {
                Text("Possible misconceptions").font(.headline)
                ForEach(digest.possibleMisconceptions) { Text("• \($0.text)") }
            }
            if !digest.followUpQuestions.isEmpty {
                Text("Follow-up questions").font(.headline)
                ForEach(digest.followUpQuestions, id: \.self) { Text("• \($0)") }
            }
            Divider()
            Text("\(artifact.trace.provider) · \(artifact.trace.model) · \(artifact.trace.promptVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
    }
}

private struct DigestCitationLinks: View {
    @Bindable var model: AppModel
    let sourceIds: [UUID]
    @State private var sources: [StoredEntity] = []

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(sources, id: \.id) { source in
                citation(source)
            }
        }
        .task(id: sourceIds) {
            guard let database = model.database else { return }
            var loaded: [StoredEntity] = []
            for id in sourceIds {
                if let entity = try? await database.entity(id: id) { loaded.append(entity) }
            }
            sources = loaded
        }
    }

    @ViewBuilder
    private func citation(_ source: StoredEntity) -> some View {
        switch source.entityType {
        case .noteBlock:
            if let noteId = source.parentId {
                NavigationLink {
                    NoteEditorView(model: model, noteId: noteId, focusedBlockId: source.id)
                } label: {
                    citationLabel("Note", id: source.id)
                }
                .buttonStyle(.bordered)
            }
        case .annotation:
            if let annotation = try? CanonicalJSON.decode(AnnotationPayload.self, from: source.content) {
                NavigationLink {
                    ResourceDetailView(
                        model: model,
                        resourceId: annotation.resourceId,
                        sessionId: annotation.studySessionId,
                        initialPageNumber: annotation.pageNumber,
                        focusedAnnotationId: source.id,
                        highlightText: annotation.selectedText
                    )
                } label: {
                    citationLabel("Page \(annotation.pageNumber ?? 1)", id: source.id)
                }
                .buttonStyle(.bordered)
            }
        default:
            citationLabel(source.entityType.rawValue.capitalized, id: source.id)
        }
    }

    private func citationLabel(_ title: String, id: UUID) -> some View {
        Label("\(title) · \(id.uuidString.prefix(8))", systemImage: "arrow.up.forward.square")
            .font(.caption2.monospaced())
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maximumWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximumWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: min(maximumWidth, max(0, x - spacing)), height: y + lineHeight), points)
    }
}

private struct DigestEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let artifact: SessionDigestArtifact
    let onSave: (SessionDigest) -> Void

    @State private var title: String
    @State private var summary: String

    init(artifact: SessionDigestArtifact, onSave: @escaping (SessionDigest) -> Void) {
        self.artifact = artifact
        self.onSave = onSave
        let digest = artifact.editedDigest ?? artifact.digest
        _title = State(initialValue: digest.title)
        _summary = State(initialValue: digest.summary)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                Section("Summary") {
                    TextEditor(text: $summary).frame(minHeight: 240)
                }
                Text("Cited key points stay intact. Editing creates a human-reviewed encrypted revision; it does not overwrite the provider trace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Edit digest")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save revision") {
                        var digest = artifact.editedDigest ?? artifact.digest
                        digest.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        digest.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(digest)
                        dismiss()
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}
