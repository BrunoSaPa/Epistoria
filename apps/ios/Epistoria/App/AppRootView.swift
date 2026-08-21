import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case today = "Today"
    case notebook = "Notebook"
    case topics = "Topics"
    case library = "Library"
    case study = "Study"
    case search = "Search"
    case settings = "Settings"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .notebook: "book.pages"
        case .topics: "square.grid.2x2"
        case .library: "books.vertical"
        case .study: "graduationcap"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

private enum AppSectionGroup: String, CaseIterable, Identifiable {
    case daily = "Daily"
    case knowledge = "Knowledge"
    case learning = "Learning"
    case utilities = "Utilities"

    var id: Self { self }

    var sections: [AppSection] {
        switch self {
        case .daily: [.today, .notebook]
        case .knowledge: [.topics, .library]
        case .learning: [.study]
        case .utilities: [.search, .settings]
        }
    }
}

struct AppRootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var workspacePresentation = EpistoriaWorkspacePresentation()

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Unlocking Epistoria…")
        case .onboarding:
            OnboardingView(model: model)
        case let .failed(message):
            ContentUnavailableView {
                Label("Epistoria is locked", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Restore with recovery words") { model.beginRecovery() }
                    .buttonStyle(.borderedProminent)
                    .tint(EpistoriaDesign.ink)
            }
        case .ready:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(selection: sectionSelection) {
                    Section {
                        HStack(spacing: 12) {
                            EpistoriaBrandMark(size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Epistoria")
                                    .font(.headline)
                                Text("The history of what you know")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }

                    ForEach(AppSectionGroup.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(group.sections) { section in
                                Label(section.rawValue, systemImage: section.symbol)
                                    .tag(section)
                                    .disabled(model.isCreatingPortableExport && section != .settings)
                                    .accessibilityIdentifier("navigation.\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Knowledge")
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 320)
                .safeAreaInset(edge: .bottom) {
                    SidebarSyncStatus(model: model)
                }
            } detail: {
                destination(model.selectedSection ?? .today)
                    .epistoriaPageBackground()
                    .environment(\.epistoriaWorkspacePresentation, workspacePresentation)
            }
            .navigationSplitViewStyle(.balanced)
            .tint(EpistoriaDesign.accent)
            .onChange(of: workspacePresentation.activeImmersiveEditorID) { _, editorID in
                setColumnVisibility(editorID == nil ? .all : .detailOnly)
            }
            .onChange(of: model.selectedSection) { _, _ in
                workspacePresentation.reset()
                setColumnVisibility(.all)
            }
            .onChange(of: model.isCreatingPortableExport) { _, isCreating in
                if isCreating {
                    model.selectedSection = .settings
                }
            }
        }
    }

    private func setColumnVisibility(_ visibility: NavigationSplitViewVisibility) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
            columnVisibility = visibility
        }
    }

    private var sectionSelection: Binding<AppSection?> {
        Binding(
            get: { model.selectedSection },
            set: { selection in
                guard !model.isCreatingPortableExport || selection == .settings else { return }
                model.selectedSection = selection
            }
        )
    }

    @ViewBuilder
    private func destination(_ section: AppSection) -> some View {
        switch section {
        case .today: TodayView(model: model)
        case .notebook: NotebookView(model: model)
        case .topics: TopicsView(model: model)
        case .library: LibraryView(model: model)
        case .study: StudyView(model: model)
        case .search: KnowledgeSearchView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

private struct SidebarSyncStatus: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if model.isCreatingPortableExport {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Creating portable export")
                } else {
                    Image(systemName: model.syncStatusSymbol)
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if model.isCreatingPortableExport {
                Label("Editing resumes automatically when the validated archive is ready.", systemImage: "lock.open.display")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sidebar.exportProgress")
            } else if model.configuration?.serverConnected == true {
                Button {
                    Task { await model.synchronize() }
                } label: {
                    Label(model.isSyncing ? "Syncing" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isSyncing)
                .accessibilityIdentifier("sidebar.sync")
            } else {
                Button("Set up private sync") {
                    model.selectedSection = .settings
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: EpistoriaDesign.compactRadius))
        .padding(10)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if model.isCreatingPortableExport { return "Creating portable export" }
        if model.isSyncing { return "Syncing safely" }
        if model.syncError != nil { return "Saved locally" }
        if model.unresolvedConflictCount > 0 { return "Review versions" }
        if model.pendingRecordCount + model.pendingFileCount > 0 { return "Saved locally" }
        if model.configuration?.serverConnected != true { return "On this iPad" }
        if model.lastSyncReport != nil { return "Up to date" }
        return "Private sync ready"
    }

    private var detail: String {
        if model.isCreatingPortableExport {
            return "Data Health stays open while Epistoria assembles one consistent local snapshot."
        }
        return model.syncStatusText
    }

    private var color: Color {
        if model.isCreatingPortableExport { return .primary }
        if model.syncError != nil || model.unresolvedConflictCount > 0 { return EpistoriaDesign.attention }
        if model.pendingRecordCount + model.pendingFileCount > 0 { return .primary }
        if model.configuration?.serverConnected == true { return EpistoriaDesign.positive }
        return EpistoriaDesign.accent
    }
}
