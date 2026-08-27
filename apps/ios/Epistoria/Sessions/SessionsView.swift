import EpistoriaCore
import SwiftUI
import UniformTypeIdentifiers

private extension StudySessionState {
    var displayName: String {
        switch self {
        case .planned: "Planned"
        case .active: "Active"
        case .paused: "Paused"
        case .ended: "Ended"
        case .abandoned: "Abandoned"
        }
    }

    var symbol: String {
        switch self {
        case .planned: "calendar"
        case .active: "circle.fill"
        case .paused: "pause.circle.fill"
        case .ended: "checkmark.circle"
        case .abandoned: "xmark.circle"
        }
    }
}

private extension SessionActivityKind {
    var displayName: String {
        switch self {
        case .noteOpened: "Note opened"
        case .noteCreated: "Note created"
        case .sourceOpened: "Source opened"
        case .sourceAdded: "Source added"
        }
    }

    var symbol: String {
        switch self {
        case .noteOpened, .noteCreated: "note.text"
        case .sourceOpened, .sourceAdded: "doc.text"
        }
    }
}

struct SessionsView: View {
    @Bindable var model: AppModel
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var courses: [IdentifiedPayload<CoursePayload>] = []
    @State private var noteCountBySessionId: [UUID: Int] = [:]
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
                        Section {
                            Label("A session is a focused study period. It collects the notes and readings used together, then preserves that study history when it ends.", systemImage: "timer")
                                .font(.subheadline)
                                .foregroundStyle(EpistoriaDesign.mutedInk)
                        }
                        let upcoming = sessions.filter { [.planned, .active, .paused].contains($0.payload.state) }
                        let history = sessions.filter { [.ended, .abandoned].contains($0.payload.state) }
                        if !upcoming.isEmpty {
                            Section("In progress") { sessionRows(upcoming) }
                        }
                        if !history.isEmpty {
                            Section("History") { sessionRows(history) }
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
                        Text(session.payload.state.displayName)
                            .font(.caption.bold())
                            .foregroundStyle(session.payload.state == .active ? EpistoriaDesign.positive : EpistoriaDesign.mutedInk)
                    }
                    Text(session.payload.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !session.payload.goals.isEmpty {
                        Text(session.payload.goals.joined(separator: " · "))
                            .font(.caption)
                            .lineLimit(2)
                    }
                    Label(
                        "\(noteCountBySessionId[session.id, default: 0]) note\(noteCountBySessionId[session.id, default: 0] == 1 ? "" : "s")",
                        systemImage: "note.text"
                    )
                    .font(.caption)
                    .foregroundStyle(EpistoriaDesign.mutedInk)
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
            var counts: [UUID: Int] = [:]
            for session in result.0 {
                counts[session.id] = try await store.noteIdsLinkedToSession(session.id).count
            }
            noteCountBySessionId = counts
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
    @State private var sessionState = StudySessionState.active
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
                Section {
                    TextField("What are you studying?", text: $title)
                } footer: {
                    Text("A session is one focused study period. Notes and Sources stay connected to their Topic after the session ends.")
                }
                if let fixedCourseId,
                   let course = courses.first(where: { $0.id == fixedCourseId })
                {
                    LabeledContent("Topic", value: course.payload.name)
                } else {
                    Picker("Topic", selection: $courseId) {
                        Text("Choose a Topic").tag(UUID?.none)
                        ForEach(courses, id: \.id) { course in
                            Text(course.payload.name).tag(Optional(course.id))
                        }
                    }
                }
                Picker("When", selection: $sessionState) {
                    Text("Start now").tag(StudySessionState.active)
                    Text("Plan for later").tag(StudySessionState.planned)
                }
                .pickerStyle(.segmented)
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
                    Button(sessionState == .planned ? "Plan" : "Start") { Task { await create() } }
                        .disabled(
                            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || courseId == nil
                        )
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
                goals: parsedGoals,
                state: sessionState,
                requireTopic: true
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
    @State private var activities: [IdentifiedPayload<SessionActivityPayload>] = []
    @State private var activityTitles: [UUID: String] = [:]
    @State private var digestArtifact: IdentifiedPayload<SessionDigestArtifact>?
    @State private var preparedDigest: PreparedDigestRequest?
    @State private var digestDisclosure: DirectProviderDisclosure?
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var showDisclosure = false
    @State private var showDigestEditor = false
    @State private var showAddExistingNotes = false
    @State private var createdNoteId: UUID?
    @State private var pendingUnlinkNote: IdentifiedPayload<NotePayload>?
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
                        if let objective = session.payload.objective, !objective.isEmpty {
                            LabeledContent("Objective", value: objective)
                                .font(.subheadline)
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

                Section {
                    if notes.isEmpty {
                        Text("No notes in this session yet")
                            .foregroundStyle(EpistoriaDesign.mutedInk)
                    }
                    ForEach(notes, id: \.id) { note in
                        NavigationLink {
                            NoteEditorView(
                                model: model,
                                noteId: note.id,
                                onLifecycleChanged: { Task { await load() } }
                            )
                            .task { await recordActivity(itemId: note.id, kind: .noteOpened) }
                        } label: {
                            NoteReviewPreview(
                                model: model,
                                note: note,
                                context: "Session · \(session.payload.title)"
                            )
                        }
                        .swipeActions {
                            Button("Remove from Session", systemImage: "link.badge.minus", role: .destructive) {
                                pendingUnlinkNote = note
                            }
                        }
                        .contextMenu {
                            Button("Remove from Session", systemImage: "link.badge.minus", role: .destructive) {
                                pendingUnlinkNote = note
                            }
                        }
                    }
                    Button("Add existing notes", systemImage: "plus.rectangle.on.rectangle") {
                        showAddExistingNotes = true
                    }
                    Button("Create a note in this session", systemImage: "square.and.pencil") {
                        Task { await createNote() }
                    }
                } header: {
                    Text("Session notes")
                } footer: {
                    Text("A session references the notes used during this focused period. The same note can remain in collections and appear in another session without being copied.")
                }

                Section("Resources") {
                    ForEach(resources, id: \.id) { resource in
                        NavigationLink(resource.payload.title) {
                            ResourceDetailView(model: model, resourceId: resource.id, sessionId: sessionId)
                        }
                    }
                    Button("Import Source for this session", systemImage: "doc.badge.plus") {
                        isImporting = true
                    }
                }

                if !activities.isEmpty {
                    Section {
                        ForEach(activities, id: \.id) { activity in
                            HStack(spacing: 12) {
                                Image(systemName: activity.payload.kind.symbol)
                                    .foregroundStyle(EpistoriaDesign.mutedInk)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(activityTitles[activity.payload.itemId] ?? activity.payload.kind.displayName)
                                    Text("\(activity.payload.kind.displayName) · \(activity.payload.occurredAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(EpistoriaDesign.mutedInk)
                                }
                            }
                            .swipeActions {
                                Button("Remove", systemImage: "xmark", role: .destructive) {
                                    Task { await removeActivity(activity.id) }
                                }
                            }
                        }
                    } header: {
                        Text("Activity")
                    } footer: {
                        Text("Removing an activity entry does not delete the note or Source.")
                    }
                }

                if [.planned, .active, .paused].contains(session.payload.state) {
                    Section {
                        if session.payload.state == .planned {
                            Button("Start session", systemImage: "play.circle.fill") {
                                Task { await setState(.active) }
                            }
                        }
                        if session.payload.state == .active {
                            Button("Pause session", systemImage: "pause.circle") {
                                Task { await setState(.paused) }
                            }
                        }
                        if session.payload.state == .paused {
                            Button("Resume session", systemImage: "play.circle") {
                                Task { await setState(.active) }
                            }
                        }
                        Button("End session", systemImage: "stop.circle", role: .destructive) {
                            Task { await endSession() }
                        }
                        Button("Abandon session", systemImage: "xmark.circle", role: .destructive) {
                            Task { await setState(.abandoned) }
                        }
                    } header: {
                        Text("Session controls")
                    } footer: {
                        Text("Ending or abandoning preserves the complete activity history. Notes and Sources remain editable.")
                    }
                } else if session.payload.state == .ended {
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
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: EpistoriaSourceImportTypes.supported
        ) { result in
            Task { await importSource(result) }
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
        .sheet(isPresented: $showAddExistingNotes) {
            AddNotesToSessionView(model: model, sessionId: sessionId) {
                Task { await load() }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Remove this note from the Session?",
            isPresented: Binding(
                get: { pendingUnlinkNote != nil },
                set: { if !$0 { pendingUnlinkNote = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Session", role: .destructive) {
                guard let pendingUnlinkNote else { return }
                Task { await unlinkNote(pendingUnlinkNote.id) }
                self.pendingUnlinkNote = nil
            }
            Button("Cancel", role: .cancel) { pendingUnlinkNote = nil }
        } message: {
            Text("The note remains in the notebook. Session activity history is not removed.")
        }
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
            } else {
                Button("Prepare cited digest", systemImage: "sparkles") {
                    Task { await prepareDigest() }
                }
                .disabled(isWorking)
                Text("Epistoria first shows which excerpts will leave this iPad, the provider, model, destination, and maximum estimated cost. No request is automatic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var disclosureSheet: some View {
        NavigationStack {
            Form {
                if let preview = preparedDigest?.preview {
                    Section("What leaves this iPad") {
                        LabeledContent("Sources", value: "\(preview.sourceCount)")
                        LabeledContent("Characters", value: preview.characterCount.formatted())
                        LabeledContent("Approximate tokens", value: preview.approximateTokens.formatted())
                        if let digestDisclosure {
                            LabeledContent("Provider", value: digestDisclosure.provider)
                            LabeledContent("Model", value: digestDisclosure.model)
                            LabeledContent("Destination", value: digestDisclosure.destination)
                            LabeledContent(
                                "Maximum estimated cost",
                                value: digestDisclosure.maximumEstimatedCostUsd.map {
                                    $0.formatted(.currency(code: "USD"))
                                } ?? "Not available"
                            )
                        }
                    }
                    Section("Source titles") {
                        ForEach(preview.sourceTitles, id: \.self) { Text($0) }
                    }
                    Section {
                        Label("Sent only after you approve", systemImage: "hand.raised")
                        Text("This iPad sends the approved excerpts directly to the provider shown above. The sync server and optional Compute Node are not used.")
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
                    Button("Approve and send") { Task { await submitDigest() } }
                        .disabled(preparedDigest == nil || digestDisclosure == nil || isWorking)
                }
            }
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: StudySessionState) -> some View {
        Label(state.displayName, systemImage: state.symbol)
            .font(.caption.bold())
            .foregroundStyle(state == .active ? EpistoriaDesign.positive : .secondary)
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            let loadedSession = try await store.payload(StudySessionPayload.self, id: sessionId)
            let allNotes = try await store.list(NotePayload.self)
            let linkedNoteIds = try await store.noteIdsLinkedToSession(sessionId)
            let relations = try await store.list(
                RelationPayload.self,
                parentId: sessionId,
                entityTypeOverride: .sessionResource
            )
            let loadedActivities = try await store.list(SessionActivityPayload.self, parentId: sessionId)
            var linkedResources: [IdentifiedPayload<ResourcePayload>] = []
            for relation in relations where relation.payload.leftId == sessionId {
                if let resource = try? await store.payload(ResourcePayload.self, id: relation.payload.rightId) {
                    linkedResources.append(resource)
                }
            }
            session = loadedSession
            notes = allNotes
                .filter { linkedNoteIds.contains($0.id) && $0.payload.archivedAt == nil }
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            resources = linkedResources
            activities = loadedActivities
                .filter { $0.payload.removedAt == nil }
                .sorted { $0.payload.occurredAt > $1.payload.occurredAt }
            var titles: [UUID: String] = [:]
            for activity in activities {
                if let note = try? await store.payload(NotePayload.self, id: activity.payload.itemId) {
                    titles[activity.payload.itemId] = note.payload.title
                } else if let source = try? await store.payload(ResourcePayload.self, id: activity.payload.itemId) {
                    titles[activity.payload.itemId] = source.payload.title
                }
            }
            activityTitles = titles
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

    private func importSource(_ result: Result<URL, Error>) async {
        guard let manager = model.assetManager else { return }
        do {
            let url = try result.get()
            _ = try await manager.importSource(
                from: url,
                topicId: session?.payload.courseId,
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

    private func setState(_ state: StudySessionState) async {
        guard let store = model.store else { return }
        do {
            try await store.setSessionState(id: sessionId, state: state)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeActivity(_ id: UUID) async {
        guard let store = model.store else { return }
        do {
            try await store.removeSessionActivity(id: id)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func unlinkNote(_ noteId: UUID) async {
        guard let store = model.store else { return }
        do {
            try await store.unlinkNote(noteId, fromSession: sessionId)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func recordActivity(itemId: UUID, kind: SessionActivityKind) async {
        guard let store = model.store,
              let state = session?.payload.state,
              state == .active || state == .paused
        else { return }
        do {
            _ = try await store.recordSessionActivity(sessionId: sessionId, itemId: itemId, kind: kind)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private func prepareDigest() async {
        guard let coordinator = model.aiJobs else {
            errorMessage = "Unlock the notebook before preparing a digest."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let value = try await coordinator.prepareSessionDigest(sessionId: sessionId)
            digestDisclosure = try model.directProviderDisclosure(
                approximateInputTokens: value.preview.approximateTokens,
                maximumOutputTokens: 4_096
            )
            preparedDigest = value
            showDisclosure = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func submitDigest() async {
        guard let preparedDigest, let digestDisclosure else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.generateSessionDigestDirect(
                preparedDigest,
                approvedRoute: digestDisclosure.route
            )
            model.noteLocalMutation()
            self.preparedDigest = nil
            self.digestDisclosure = nil
            showDisclosure = false
            await load()
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
