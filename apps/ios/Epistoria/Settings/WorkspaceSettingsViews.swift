import EpistoriaCore
import SwiftUI

struct InterfaceControlsSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.editMode) private var editMode

    var body: some View {
        List {
            Section {
                Toggle(
                    "Pin Learning in the sidebar",
                    isOn: Binding(
                        get: { model.workspacePreferences.learningPinned },
                        set: { model.workspacePreferences.learningPinned = $0 }
                    )
                )
                Text("Learning remains available from Today, Topics, notebooks, and Sources when it is not pinned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sidebar")
            }

            Section("Order and visibility") {
                ForEach(model.workspacePreferences.sidebarOrder) { section in
                    HStack {
                        Label(section.rawValue, systemImage: section.symbol)
                        Spacer()
                        if section == .today || section == .notebook {
                            Text("Always shown").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Toggle(
                                "Show \(section.rawValue)",
                                isOn: Binding(
                                    get: { !model.workspacePreferences.hiddenSidebarItems.contains(section) },
                                    set: { model.workspacePreferences.setSidebarVisible(section, visible: $0) }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                }
                .onMove(perform: model.workspacePreferences.moveSidebarItems)
                Button("Restore sidebar defaults", systemImage: "arrow.counterclockwise") {
                    model.workspacePreferences.resetSidebar()
                }
            }

            Section("Notebook rail") {
                ForEach(model.workspacePreferences.notebookToolOrder) { tool in
                    Label(tool.title, systemImage: tool.symbol)
                }
                .onMove(perform: model.workspacePreferences.moveNotebookTools)
                Text("Writing tools stay on the rail. Optional tools open from More unless pinned below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pinned optional tools") {
                ForEach(NotebookToolID.optional) { tool in
                    Toggle(
                        isOn: Binding(
                            get: { model.workspacePreferences.pinnedOptionalTools.contains(tool) },
                            set: { enabled in
                                if enabled { model.workspacePreferences.pinnedOptionalTools.insert(tool) }
                                else { model.workspacePreferences.pinnedOptionalTools.remove(tool) }
                            }
                        )
                    ) {
                        Label(tool.title, systemImage: tool.symbol)
                    }
                }
                Button("Restore notebook rail defaults", systemImage: "arrow.counterclockwise") {
                    model.workspacePreferences.resetNotebookRail()
                }
            }
        }
        .navigationTitle("Interface and Controls")
        .toolbar { EditButton() }
    }
}

struct NotebookDefaultsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("New notes") {
                Picker("Page size", selection: preferenceBinding(\.defaultPageFormat)) {
                    Text("A4").tag(NotePageFormat.a4)
                    Text("US Letter").tag(NotePageFormat.letter)
                    Text("Infinite canvas").tag(NotePageFormat.infinite)
                }
                if model.workspacePreferences.defaultPageFormat != .infinite {
                    Picker("Orientation", selection: preferenceBinding(\.defaultPageOrientation)) {
                        Text("Portrait").tag(NotePageOrientation.portrait)
                        Text("Landscape").tag(NotePageOrientation.landscape)
                    }
                }
                Picker("Paper", selection: preferenceBinding(\.defaultPaperStyle)) {
                    ForEach(NotePaperStyle.allCases, id: \.self) { style in
                        Text(style.settingsTitle).tag(style)
                    }
                }
                Picker("Page color", selection: preferenceBinding(\.defaultPaperColor)) {
                    ForEach(NotePaperColor.allCases, id: \.self) { color in
                        Text(color.settingsTitle).tag(color)
                    }
                }
            }
            Section {
                Text("These defaults apply only to notes created on this iPad. Existing notes keep their saved page settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notebook Defaults")
    }

    private func preferenceBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<WorkspacePreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.workspacePreferences[keyPath: keyPath] },
            set: { model.workspacePreferences[keyPath: keyPath] = $0 }
        )
    }
}

struct ProcessingActivityView: View {
    @Bindable var model: AppModel
    @State private var jobs: [ProcessingJob] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if activeJobs.isEmpty {
                    ContentUnavailableView(
                        "No active processing",
                        systemImage: "checkmark.circle",
                        description: Text("Notebook work does not require a Compute Node.")
                    )
                } else {
                    ForEach(activeJobs) { job in jobRow(job) }
                }
            } header: {
                Text("Active")
            }

            Section("Recent") {
                if recentJobs.isEmpty { Text("No completed work yet.").foregroundStyle(.secondary) }
                ForEach(recentJobs.prefix(30)) { job in jobRow(job) }
            }
        }
        .navigationTitle("Processing Activity")
        .task { await load() }
        .refreshable { await load() }
        .alert("Processing problem", isPresented: .constant(errorMessage != nil)) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var activeJobs: [ProcessingJob] { jobs.filter { !$0.state.isTerminal } }
    private var recentJobs: [ProcessingJob] { jobs.filter { $0.state.isTerminal } }

    private func jobRow(_ job: ProcessingJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(jobTitle(job), systemImage: routeSymbol(job.selectedRoute))
                    .font(.headline)
                Spacer()
                Text(stateTitle(job.state)).font(.caption).foregroundStyle(.secondary)
            }
            Text(routeDetail(job))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let progress = job.progress {
                ProgressView(value: progress)
            }
            if job.state == .failed {
                Button("Retry on iPad") { Task { await retryOnIPad(job) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if !job.state.isTerminal {
                HStack {
                    if job.state == .running || job.state == .queued {
                        Button("Pause") { Task { await transition(job, to: .paused) } }
                    } else if job.state == .paused || job.state == .waitingForCapability
                                || job.state == .waitingForNetwork {
                        Button("Retry on iPad") { Task { await retryOnIPad(job) } }
                    }
                    Button("Cancel", role: .destructive) { Task { await transition(job, to: .cancelled) } }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }

    @MainActor private func load() async {
        do { jobs = try await model.database?.processingJobs() ?? [] }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func transition(_ job: ProcessingJob, to state: ProcessingJobState) async {
        do {
            _ = try await model.database?.transitionProcessingJob(id: job.id, to: state)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func retryOnIPad(_ job: ProcessingJob) async {
        do {
            guard job.requiredCapabilities.allSatisfy({ onDeviceCapabilities.contains($0) }) else {
                errorMessage = "This job needs a capability that is not available on this iPad. It will remain safely queued."
                return
            }
            guard var changed = try await model.database?.processingJob(id: job.id) else { return }
            changed.state = .queued
            changed.selectedRoute = .onDevice
            changed.computeNodeId = nil
            changed.errorCode = nil
            changed.updatedAt = .now
            _ = try await model.database?.saveProcessingJob(changed)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    private var onDeviceCapabilities: Set<ProcessingCapability> {
        [.textRecognition, .formulaRecognition, .sourceExtraction, .hostedProvider]
    }

    private func jobTitle(_ job: ProcessingJob) -> String {
        job.kind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func stateTitle(_ state: ProcessingJobState) -> String {
        state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func routeSymbol(_ route: ProcessingRoute?) -> String {
        switch route {
        case .onDevice: "ipad"
        case .directProvider: "network"
        case .computeNode: "desktopcomputer"
        case nil: "hourglass"
        }
    }

    private func routeDetail(_ job: ProcessingJob) -> String {
        switch job.selectedRoute {
        case .onDevice: "Running privately on this iPad"
        case .directProvider: "Direct provider request from this iPad"
        case .computeNode: "Using an approved optional Compute Node"
        case nil: "Waiting for a compatible approved route"
        }
    }
}

struct TrashView: View {
    @Bindable var model: AppModel
    @State private var entries: [IdentifiedPayload<TrashEntryPayload>] = []
    @State private var showEmptyConfirmation = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Trash is empty",
                    systemImage: "trash",
                    description: Text("Deleted items remain here until you empty Trash manually.")
                )
            } else {
                Section {
                    ForEach(entries, id: \.id) { entry in
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.payload.displayName)
                                    Text("\(entry.payload.targetType.trashTitle) · \(entry.payload.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: entry.payload.targetType.trashSymbol)
                            }
                            Spacer()
                            Button("Restore") { Task { await restore(entry.id) } }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("trash.restore.\(entry.payload.targetId.uuidString)")
                        }
                    }
                } footer: {
                    Text("Items are encrypted and never expire automatically.")
                }
            }
        }
        .navigationTitle("Trash")
        .toolbar {
            if !entries.isEmpty {
                Button("Empty Trash…", role: .destructive) { showEmptyConfirmation = true }
            }
        }
        .task { await load() }
        .confirmationDialog(
            "Permanently remove unprotected items?",
            isPresented: $showEmptyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { Task { await emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Referenced Sources remain protected. Other items cannot be recovered after synchronized deletion.")
        }
        .alert("Trash", isPresented: Binding(
            get: { resultMessage != nil || errorMessage != nil },
            set: { if !$0 { resultMessage = nil; errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { resultMessage = nil; errorMessage = nil }
        } message: { Text(errorMessage ?? resultMessage ?? "") }
    }

    @MainActor private func load() async {
        do { entries = try await model.store?.trashEntries() ?? [] }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func restore(_ id: UUID) async {
        do {
            try await model.store?.restoreTrashEntry(id: id)
            model.noteLocalMutation()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func emptyTrash() async {
        do {
            guard let result = try await model.store?.emptyTrash() else { return }
            model.noteLocalMutation()
            resultMessage = result.protectedCount == 0
                ? "Permanently removed \(result.deletedCount) item\(result.deletedCount == 1 ? "" : "s")."
                : "Removed \(result.deletedCount). Kept \(result.protectedCount) referenced item\(result.protectedCount == 1 ? "" : "s")."
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension NotePaperStyle {
    var settingsTitle: String { rawValue.lowercased().capitalized }
}

private extension NotePaperColor {
    var settingsTitle: String { rawValue.lowercased().capitalized }
}

private extension EntityType {
    var trashTitle: String {
        switch self {
        case .note: "Note"
        case .notePage: "Page"
        case .noteBlock: "Canvas item"
        case .source: "Source"
        case .list: "List"
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var trashSymbol: String {
        switch self {
        case .note: "note.text"
        case .notePage: "doc"
        case .noteBlock: "square.dashed"
        case .source: "books.vertical"
        case .list: "folder"
        default: "trash"
        }
    }
}
