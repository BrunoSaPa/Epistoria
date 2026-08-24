import EpistoriaCore
import SwiftUI
import UniformTypeIdentifiers

struct UniversityView: View {
    private enum CourseShelf: String, CaseIterable, Identifiable {
        case active = "Active"
        case archived = "Archived"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    @State private var institutions: [IdentifiedPayload<InstitutionPayload>] = []
    @State private var terms: [IdentifiedPayload<AcademicTermPayload>] = []
    @State private var courses: [IdentifiedPayload<CoursePayload>] = []
    @State private var shelf = CourseShelf.active
    @State private var newKind: NewUniversityKind?
    @State private var createdCourseId: UUID?
    @State private var pendingArchive: IdentifiedPayload<CoursePayload>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Institutions") {
                    if institutions.isEmpty {
                        Button("Add your institution", systemImage: "building.columns") {
                            newKind = .institution
                        }
                    }
                    ForEach(institutions, id: \.id) { institution in
                        NavigationLink {
                            InstitutionDetailView(
                                model: model,
                                institution: institution,
                                terms: terms,
                                courses: courses,
                                onCourseChanged: { Task { await load() } }
                            )
                        } label: {
                            UniversityStructureRow(
                                title: institution.payload.name,
                                detail: institutionDetail(institution.id),
                                symbol: "building.columns"
                            )
                        }
                        .accessibilityIdentifier("university.institution.\(institution.id.uuidString)")
                    }
                }

                Section("Academic terms") {
                    if terms.isEmpty {
                        Button("Add an academic term", systemImage: "calendar.badge.plus") {
                            newKind = .term
                        }
                        .disabled(institutions.isEmpty)
                    }
                    ForEach(terms, id: \.id) { term in
                        NavigationLink {
                            TermDetailView(
                                model: model,
                                term: term,
                                institutionName: institutionName(term.payload.institutionId),
                                courses: courses,
                                onCourseChanged: { Task { await load() } }
                            )
                        } label: {
                            UniversityStructureRow(
                                title: term.payload.name,
                                detail: termDetail(term),
                                symbol: "calendar"
                            )
                        }
                        .accessibilityIdentifier("university.term.\(term.id.uuidString)")
                    }
                }

                Section {
                    Picker("Course status", selection: $shelf) {
                        ForEach(CourseShelf.allCases) { shelf in
                            Text(shelf.rawValue).tag(shelf)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("university.course-shelf")
                }

                Section(shelf == .active ? "Active courses" : "Archived courses") {
                    if visibleCourses.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Label(
                                shelf == .active ? "No active courses" : "No archived courses",
                                systemImage: shelf == .active ? "books.vertical" : "archivebox"
                            )
                            .font(.headline)
                            Text(
                                shelf == .active
                                    ? "Add a course to connect its notes, readings, and study sessions."
                                    : "Courses you archive will remain available here with all of their linked work."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            if shelf == .active {
                                Button("Add a course") { newKind = .course }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    ForEach(visibleCourses, id: \.id) { course in
                        NavigationLink {
                            CourseDetailView(
                                model: model,
                                courseId: course.id,
                                onCourseChanged: { Task { await load() } }
                            )
                        } label: {
                            CourseRow(course: course)
                        }
                        .accessibilityIdentifier("university.course.\(course.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if course.payload.archived {
                                Button("Restore", systemImage: "arrow.uturn.backward") {
                                    Task { await setArchived(course, archived: false) }
                                }
                                .tint(EpistoriaDesign.accent)
                            } else {
                                Button("Archive", systemImage: "archivebox") {
                                    pendingArchive = course
                                }
                                .tint(.gray)
                            }
                        }
                    }
                }
            }
            .navigationTitle("University")
            .epistoriaPageBackground()
            .toolbar {
                Menu {
                    Button("Institution", systemImage: "building.columns") { newKind = .institution }
                    Button("Academic term", systemImage: "calendar.badge.plus") { newKind = .term }
                        .disabled(institutions.isEmpty)
                    Button("Course", systemImage: "book.closed") { newKind = .course }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            .sheet(item: $newKind) { kind in
                NewUniversityItemView(
                    model: model,
                    kind: kind,
                    institutions: institutions,
                    terms: terms
                ) { id in
                    Task {
                        await load()
                        if kind == .course {
                            shelf = .active
                            createdCourseId = id
                        }
                    }
                }
            }
            .navigationDestination(item: $createdCourseId) { id in
                CourseDetailView(
                    model: model,
                    courseId: id,
                    onCourseChanged: { Task { await load() } }
                )
            }
            .confirmationDialog(
                "Archive this course?",
                isPresented: Binding(
                    get: { pendingArchive != nil },
                    set: { if !$0 { pendingArchive = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Archive course") {
                    guard let pendingArchive else { return }
                    Task { await setArchived(pendingArchive, archived: true) }
                    self.pendingArchive = nil
                }
                Button("Cancel", role: .cancel) { pendingArchive = nil }
            } message: {
                Text("Its notes, resources, and sessions stay encrypted and linked. You can restore it from Archived courses.")
            }
            .task { await load() }
            .refreshable { await load() }
            .alert("University error", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await load() } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var visibleCourses: [IdentifiedPayload<CoursePayload>] {
        courses.filter { $0.payload.archived == (shelf == .archived) }
    }

    private func institutionDetail(_ institutionId: UUID) -> String {
        let termCount = terms.filter { $0.payload.institutionId == institutionId }.count
        let courseCount = courses.filter { $0.payload.institutionId == institutionId }.count
        return "\(termCount) term\(termCount == 1 ? "" : "s") · \(courseCount) course\(courseCount == 1 ? "" : "s")"
    }

    private func termDetail(_ term: IdentifiedPayload<AcademicTermPayload>) -> String {
        let count = courses.filter { $0.payload.academicTermId == term.id }.count
        return "\(institutionName(term.payload.institutionId)) · \(count) course\(count == 1 ? "" : "s")"
    }

    private func institutionName(_ id: UUID) -> String {
        institutions.first(where: { $0.id == id })?.payload.name ?? "Institution"
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedInstitutions = store.list(InstitutionPayload.self)
            async let loadedTerms = store.list(AcademicTermPayload.self)
            async let loadedCourses = store.list(CoursePayload.self)
            let result = try await (loadedInstitutions, loadedTerms, loadedCourses)
            institutions = result.0.sorted {
                $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending
            }
            terms = result.1.sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            courses = result.2.sorted {
                $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setArchived(_ course: IdentifiedPayload<CoursePayload>, archived: Bool) async {
        guard let store = model.store else { return }
        var changed = course
        changed.payload.archived = archived
        changed.payload.updatedAt = .now
        do {
            _ = try await store.save(
                id: changed.id,
                payload: changed.payload,
                parentId: changed.payload.academicTermId ?? changed.payload.institutionId,
                relationIds: [changed.payload.institutionId, changed.payload.academicTermId].compactMap(\.self)
            )
            model.noteLocalMutation()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct UniversityStructureRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(EpistoriaDesign.accent)
                .frame(width: 34, height: 34)
                .background(EpistoriaDesign.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CourseRow: View {
    let course: IdentifiedPayload<CoursePayload>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: course.payload.archived ? "archivebox" : "book.closed.fill")
                .foregroundStyle(course.payload.archived ? .secondary : EpistoriaDesign.accent)
                .frame(width: 38, height: 38)
                .background(EpistoriaDesign.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(course.payload.name)
                        .font(.headline)
                    if course.payload.archived {
                        Text("Archived")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(EpistoriaDesign.attention)
                    }
                }
                let detail = [course.payload.code, course.payload.professor]
                    .compactMap(\.self)
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct InstitutionDetailView: View {
    @Bindable var model: AppModel
    let institution: IdentifiedPayload<InstitutionPayload>
    let terms: [IdentifiedPayload<AcademicTermPayload>]
    let courses: [IdentifiedPayload<CoursePayload>]
    let onCourseChanged: () -> Void

    var body: some View {
        List {
            Section {
                Label("Institution", systemImage: "building.columns")
                    .foregroundStyle(.secondary)
                LabeledContent("Added", value: institution.payload.createdAt.formatted(date: .abbreviated, time: .omitted))
            }
            Section("Academic terms") {
                let linkedTerms = terms.filter { $0.payload.institutionId == institution.id }
                if linkedTerms.isEmpty {
                    Text("No terms linked yet").foregroundStyle(.secondary)
                }
                ForEach(linkedTerms, id: \.id) { term in
                    NavigationLink {
                        TermDetailView(
                            model: model,
                            term: term,
                            institutionName: institution.payload.name,
                            courses: courses,
                            onCourseChanged: onCourseChanged
                        )
                    } label: {
                        Label(term.payload.name, systemImage: "calendar")
                    }
                }
            }
            courseSections(courses.filter { $0.payload.institutionId == institution.id })
        }
        .navigationTitle(institution.payload.name)
        .epistoriaPageBackground()
    }

    @ViewBuilder
    private func courseSections(_ values: [IdentifiedPayload<CoursePayload>]) -> some View {
        let active = values.filter { !$0.payload.archived }
        let archived = values.filter(\.payload.archived)
        Section("Courses") {
            if active.isEmpty { Text("No active courses").foregroundStyle(.secondary) }
            ForEach(active, id: \.id) { course in courseLink(course) }
        }
        if !archived.isEmpty {
            Section("Archived courses") {
                ForEach(archived, id: \.id) { course in courseLink(course) }
            }
        }
    }

    private func courseLink(_ course: IdentifiedPayload<CoursePayload>) -> some View {
        NavigationLink {
            CourseDetailView(model: model, courseId: course.id, onCourseChanged: onCourseChanged)
        } label: {
            CourseRow(course: course)
        }
    }
}

private struct TermDetailView: View {
    @Bindable var model: AppModel
    let term: IdentifiedPayload<AcademicTermPayload>
    let institutionName: String
    let courses: [IdentifiedPayload<CoursePayload>]
    let onCourseChanged: () -> Void

    var body: some View {
        List {
            Section("Details") {
                LabeledContent("Institution", value: institutionName)
                if let startDate = term.payload.startDate {
                    LabeledContent("Starts", value: startDate.formatted(date: .abbreviated, time: .omitted))
                }
                if let endDate = term.payload.endDate {
                    LabeledContent("Ends", value: endDate.formatted(date: .abbreviated, time: .omitted))
                }
            }
            let linked = courses.filter { $0.payload.academicTermId == term.id }
            Section("Courses") {
                if linked.isEmpty { Text("No courses linked yet").foregroundStyle(.secondary) }
                ForEach(linked.filter { !$0.payload.archived }, id: \.id) { course in
                    courseLink(course)
                }
            }
            if linked.contains(where: \.payload.archived) {
                Section("Archived courses") {
                    ForEach(linked.filter(\.payload.archived), id: \.id) { course in
                        courseLink(course)
                    }
                }
            }
        }
        .navigationTitle(term.payload.name)
        .epistoriaPageBackground()
    }

    private func courseLink(_ course: IdentifiedPayload<CoursePayload>) -> some View {
        NavigationLink {
            CourseDetailView(model: model, courseId: course.id, onCourseChanged: onCourseChanged)
        } label: {
            CourseRow(course: course)
        }
    }
}

private enum CourseDestination: Hashable {
    case note(UUID)
    case resource(UUID)
    case session(UUID)
}

struct CourseDetailView: View {
    @Bindable var model: AppModel
    let courseId: UUID
    let onCourseChanged: () -> Void

    @State private var course: IdentifiedPayload<CoursePayload>?
    @State private var institutionName: String?
    @State private var termName: String?
    @State private var notes: [IdentifiedPayload<NotePayload>] = []
    @State private var archivedNoteCount = 0
    @State private var resources: [IdentifiedPayload<ResourcePayload>] = []
    @State private var sessions: [IdentifiedPayload<StudySessionPayload>] = []
    @State private var destination: CourseDestination?
    @State private var showNewNote = false
    @State private var showNewSession = false
    @State private var isImporting = false
    @State private var showArchiveConfirmation = false
    @State private var importProgress: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        courseList
        .navigationTitle(course?.payload.name ?? "Course")
        .navigationBarTitleDisplayMode(.inline)
        .epistoriaPageBackground()
        .toolbar {
            courseToolbar
        }
        .sheet(isPresented: $showNewNote) {
            newNoteSheet
        }
        .sheet(isPresented: $showNewSession) {
            newSessionSheet
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: EpistoriaSourceImportTypes.supported,
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .navigationDestination(item: $destination) { destination in
            courseDestination(destination)
        }
        .confirmationDialog(
            "Archive this course?",
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive course") { Task { await setArchived(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its notes, Sources, and sessions remain linked and can be restored with the course.")
        }
        .safeAreaInset(edge: .bottom) {
            importStatus
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("Course error", isPresented: .constant(errorMessage != nil)) {
            Button("Try again") { Task { await load() } }
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var courseList: some View {
        List {
            if isLoading {
                ProgressView("Opening course…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if let course {
                courseHeader(course)
                beginSection(course)
                notesSection(course)
                resourcesSection(course)
                sessionsSection(course)
                detailsSection(course)
            } else {
                ContentUnavailableView {
                    Label("Course unavailable", systemImage: "book.closed")
                } description: {
                    Text("This encrypted course record could not be opened.")
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            }
        }
    }

    private func courseHeader(_ course: IdentifiedPayload<CoursePayload>) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.payload.name)
                            .font(.largeTitle.bold())
                        if !courseSubtitle(course).isEmpty {
                            Text(courseSubtitle(course))
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    EpistoriaStatusPill(
                        title: course.payload.archived ? "Archived" : "Active",
                        symbol: course.payload.archived ? "archivebox" : "circle.fill",
                        tone: course.payload.archived ? .attention : .positive
                    )
                }
                if course.payload.archived {
                    Text("All linked work is preserved. Restore this course before adding new material.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Restore course") { Task { await setArchived(false) } }
                        .buttonStyle(.borderedProminent)
                        .tint(EpistoriaDesign.ink)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func beginSection(_ course: IdentifiedPayload<CoursePayload>) -> some View {
        if !course.payload.archived {
            Section("Begin") {
                HStack(spacing: 10) {
                    courseAction("New note", symbol: "square.and.pencil") { showNewNote = true }
                    courseAction("Start session", symbol: "play.circle") { showNewSession = true }
                    courseAction("Import Source", symbol: "doc.badge.plus") { isImporting = true }
                }
            }
        }
    }

    private func notesSection(_ course: IdentifiedPayload<CoursePayload>) -> some View {
        Section {
            if notes.isEmpty {
                Button("Create the first course note", systemImage: "square.and.pencil") {
                    showNewNote = true
                }
                .disabled(course.payload.archived)
            }
            ForEach(notes.prefix(6), id: \.id) { note in
                NavigationLink {
                    NoteEditorView(
                        model: model,
                        noteId: note.id,
                        onLifecycleChanged: { Task { await load() } }
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.payload.title).font(.headline)
                        Text(note.payload.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Recent notes")
        } footer: {
            if archivedNoteCount > 0 {
                Text("\(archivedNoteCount) archived note\(archivedNoteCount == 1 ? " is" : "s are") available in Notebook → Archived.")
            }
        }
    }

    private func resourcesSection(_ course: IdentifiedPayload<CoursePayload>) -> some View {
        Section("Resources") {
            if resources.isEmpty {
                Button("Import the first Source", systemImage: "doc.badge.plus") {
                    isImporting = true
                }
                .disabled(course.payload.archived)
            }
            ForEach(resources.prefix(6), id: \.id) { resource in
                NavigationLink {
                    ResourceDetailView(model: model, resourceId: resource.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(resource.payload.title, systemImage: "doc.richtext")
                            .font(.headline)
                        Text(resource.payload.importedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sessionsSection(_ course: IdentifiedPayload<CoursePayload>) -> some View {
        Section("Study sessions") {
            if sessions.isEmpty {
                Button("Start the first course session", systemImage: "play.circle") {
                    showNewSession = true
                }
                .disabled(course.payload.archived)
            }
            ForEach(sessions.prefix(6), id: \.id) { session in
                NavigationLink {
                    SessionDetailView(model: model, sessionId: session.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(session.payload.title).font(.headline)
                            Spacer()
                            if session.payload.state == .active {
                                EpistoriaStatusPill(title: "Live", symbol: "circle.fill", tone: .positive)
                            }
                        }
                        Text(session.payload.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailsSection(_ course: IdentifiedPayload<CoursePayload>) -> some View {
        Section("Course details") {
            if let institutionName { LabeledContent("Institution", value: institutionName) }
            if let termName { LabeledContent("Academic term", value: termName) }
            if let code = course.payload.code, !code.isEmpty { LabeledContent("Code", value: code) }
            if let professor = course.payload.professor, !professor.isEmpty { LabeledContent("Professor", value: professor) }
            if let startDate = course.payload.startDate {
                LabeledContent("Starts", value: startDate.formatted(date: .abbreviated, time: .omitted))
            }
            if let endDate = course.payload.endDate {
                LabeledContent("Ends", value: endDate.formatted(date: .abbreviated, time: .omitted))
            }
            if let description = course.payload.courseDescription, !description.isEmpty {
                Text(description)
            }
        }
    }

    @ToolbarContentBuilder
    private var courseToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            if let course {
                if course.payload.archived {
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        Task { await setArchived(false) }
                    }
                } else {
                    Button("Archive…", systemImage: "archivebox") {
                        showArchiveConfirmation = true
                    }
                }
            }
        }
    }

    private var newNoteSheet: some View {
        NewNoteView(model: model, courseId: courseId) { id in
            Task {
                await load()
                destination = .note(id)
            }
        }
    }

    private var newSessionSheet: some View {
        NewSessionView(
            model: model,
            courses: course.map { [$0] } ?? [],
            fixedCourseId: courseId
        ) { id in
            Task {
                await load()
                destination = .session(id)
            }
        }
    }

    @ViewBuilder
    private func courseDestination(_ destination: CourseDestination) -> some View {
        switch destination {
        case let .note(id):
            NoteEditorView(
                model: model,
                noteId: id,
                onLifecycleChanged: { Task { await load() } }
            )
        case let .resource(id):
            ResourceDetailView(model: model, resourceId: id)
        case let .session(id):
            SessionDetailView(model: model, sessionId: id)
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        if let importProgress {
            HStack(spacing: 10) {
                ProgressView()
                Text(importProgress)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 3)
            .padding()
        }
    }

    private func courseSubtitle(_ course: IdentifiedPayload<CoursePayload>) -> String {
        [course.payload.code, course.payload.professor]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func courseAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("course.action.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private func load() async {
        guard let store = model.store else { return }
        isLoading = true
        do {
            let loadedCourse = try await store.payload(CoursePayload.self, id: courseId)
            async let loadedNotes = store.list(NotePayload.self)
            async let loadedResources = store.list(ResourcePayload.self, parentId: courseId)
            async let loadedSessions = store.list(StudySessionPayload.self)
            let result = try await (loadedNotes, loadedResources, loadedSessions)
            let linkedNotes = result.0.filter { $0.payload.courseId == courseId }
            course = loadedCourse
            notes = linkedNotes
                .filter { $0.payload.archivedAt == nil }
                .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
            archivedNoteCount = linkedNotes.filter { $0.payload.archivedAt != nil }.count
            resources = result.1.sorted { $0.payload.importedAt > $1.payload.importedAt }
            sessions = result.2
                .filter { $0.payload.courseId == courseId }
                .sorted { $0.payload.startedAt > $1.payload.startedAt }
            if let institutionId = loadedCourse.payload.institutionId {
                institutionName = try? await store.payload(InstitutionPayload.self, id: institutionId).payload.name
            } else {
                institutionName = nil
            }
            if let termId = loadedCourse.payload.academicTermId {
                termName = try? await store.payload(AcademicTermPayload.self, id: termId).payload.name
            } else {
                termName = nil
            }
            errorMessage = nil
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func setArchived(_ archived: Bool) async {
        guard let store = model.store, var course else { return }
        guard course.payload.archived != archived else { return }
        course.payload.archived = archived
        course.payload.updatedAt = .now
        do {
            _ = try await store.save(
                id: course.id,
                payload: course.payload,
                parentId: course.payload.academicTermId ?? course.payload.institutionId,
                relationIds: [course.payload.institutionId, course.payload.academicTermId].compactMap(\.self)
            )
            self.course = course
            model.noteLocalMutation()
            onCourseChanged()
            await load()
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
                let imported = try await assetManager.importSource(from: url, topicId: courseId)
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

private enum NewUniversityKind: String, Identifiable {
    case institution = "Institution"
    case term = "Academic term"
    case course = "Course"
    var id: Self { self }
}

private struct NewUniversityItemView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: NewUniversityKind
    let institutions: [IdentifiedPayload<InstitutionPayload>]
    let terms: [IdentifiedPayload<AcademicTermPayload>]
    let onCreated: (UUID) -> Void
    @State private var name = ""
    @State private var code = ""
    @State private var professor = ""
    @State private var institutionId: UUID?
    @State private var termId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                if kind != .institution {
                    Picker("Institution", selection: $institutionId) {
                        Text("None").tag(UUID?.none)
                        ForEach(institutions, id: \.id) { Text($0.payload.name).tag(Optional($0.id)) }
                    }
                }
                if kind == .course {
                    Picker("Term", selection: $termId) {
                        Text("None").tag(UUID?.none)
                        ForEach(availableTerms, id: \.id) { Text($0.payload.name).tag(Optional($0.id)) }
                    }
                    TextField("Course code", text: $code)
                    TextField("Professor", text: $professor)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(kind.rawValue)
            .onAppear { institutionId = institutions.first?.id }
            .onChange(of: institutionId) { _, _ in
                guard let termId,
                      availableTerms.contains(where: { $0.id == termId })
                else {
                    self.termId = nil
                    return
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var availableTerms: [IdentifiedPayload<AcademicTermPayload>] {
        guard let institutionId else { return [] }
        return terms.filter { $0.payload.institutionId == institutionId }
    }

    private func create() async {
        guard let store = model.store else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let id: UUID
            switch kind {
            case .institution:
                id = try await store.save(payload: InstitutionPayload(name: cleanName))
            case .term:
                guard let institutionId else { return }
                id = try await store.save(
                    payload: AcademicTermPayload(institutionId: institutionId, name: cleanName),
                    parentId: institutionId,
                    relationIds: [institutionId]
                )
            case .course:
                id = try await store.save(
                    payload: CoursePayload(
                        name: cleanName,
                        institutionId: institutionId,
                        academicTermId: termId,
                        code: code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : code.trimmingCharacters(in: .whitespacesAndNewlines),
                        professor: professor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : professor.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    parentId: termId ?? institutionId,
                    relationIds: [institutionId, termId].compactMap(\.self)
                )
            }
            model.noteLocalMutation()
            onCreated(id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
