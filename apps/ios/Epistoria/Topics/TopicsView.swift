import EpistoriaCore
import SwiftUI

struct TopicsView: View {
    private enum Shelf: String, CaseIterable, Identifiable {
        case active = "Active"
        case archived = "Archived"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    @State private var areas: [IdentifiedPayload<AreaPayload>] = []
    @State private var topics: [IdentifiedPayload<TopicPayload>] = []
    @State private var shelf = Shelf.active
    @State private var showNewArea = false
    @State private var showNewTopic = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Topic status", selection: $shelf) {
                        ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                ForEach(areas.filter { $0.payload.archivedAt == nil }, id: \.id) { area in
                    Section(area.payload.name) {
                        let children = visibleTopics.filter { $0.payload.primaryAreaId == area.id }
                        if children.isEmpty {
                            Text("No Topics in this Area")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(children, id: \.id) { topic in
                            topicLink(topic)
                        }
                    }
                }

                let unassigned = visibleTopics.filter { $0.payload.primaryAreaId == nil }
                if !unassigned.isEmpty || areas.isEmpty {
                    Section("Unassigned") {
                        if unassigned.isEmpty {
                            ContentUnavailableView(
                                "No Topics yet",
                                systemImage: "square.grid.2x2",
                                description: Text("Create an Area, then add a Topic for anything you want to learn.")
                            )
                        }
                        ForEach(unassigned, id: \.id) { topic in topicLink(topic) }
                    }
                }
            }
            .navigationTitle("Topics")
            .epistoriaPageBackground()
            .toolbar {
                Menu {
                    Button("Area", systemImage: "folder.badge.plus") { showNewArea = true }
                    Button("Topic", systemImage: "plus.square") { showNewTopic = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            .sheet(isPresented: $showNewArea) {
                NewAreaView(model: model) { Task { await load() } }
            }
            .sheet(isPresented: $showNewTopic) {
                NewTopicView(model: model, areas: areas) { Task { await load() } }
            }
            .task { await load() }
            .refreshable { await load() }
            .alert("Topics error", isPresented: .constant(errorMessage != nil)) {
                Button("Try again") { Task { await load() } }
                Button("Dismiss", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var visibleTopics: [IdentifiedPayload<TopicPayload>] {
        topics.filter { $0.payload.archived == (shelf == .archived) }
    }

    private func topicLink(_ topic: IdentifiedPayload<TopicPayload>) -> some View {
        NavigationLink {
            TopicDashboardView(model: model, topicId: topic.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.payload.name)
                    .font(.body.weight(.medium))
                let detail = [topic.payload.code, topic.payload.officialClassName, topic.payload.professor]
                    .compactMap(\ .self).joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("topics.topic.\(topic.id.uuidString)")
    }

    private func load() async {
        guard let store = model.store else { return }
        do {
            async let loadedAreas = store.list(AreaPayload.self)
            async let loadedTopics = store.topics()
            let values = try await (loadedAreas, loadedTopics)
            areas = values.0.sorted { $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending }
            topics = values.1.sorted { $0.payload.name.localizedCaseInsensitiveCompare($1.payload.name) == .orderedAscending }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct NewAreaView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var details = ""
    @State private var errorMessage: String?
    let onCreated: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Area name", text: $name)
                TextField("Description (optional)", text: $details, axis: .vertical)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New Area")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            _ = try await store.createArea(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: details.nilIfBlank
            )
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct NewTopicView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let areas: [IdentifiedPayload<AreaPayload>]
    let onCreated: () -> Void
    @State private var name = ""
    @State private var primaryAreaId: UUID?
    @State private var officialClassName = ""
    @State private var code = ""
    @State private var professor = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Topic") {
                    TextField("Topic name", text: $name)
                    Picker("Primary Area", selection: $primaryAreaId) {
                        Text("Unassigned").tag(UUID?.none)
                        ForEach(areas, id: \.id) { Text($0.payload.name).tag(Optional($0.id)) }
                    }
                }
                Section("Academic details (optional)") {
                    TextField("Official class name", text: $officialClassName)
                    TextField("Code", text: $code)
                    TextField("Professor", text: $professor)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("New Topic")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        guard let store = model.store else { return }
        do {
            let id = UUID()
            let topic = TopicPayload(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                primaryAreaId: primaryAreaId,
                officialClassName: officialClassName.nilIfBlank,
                code: code.nilIfBlank,
                professor: professor.nilIfBlank
            )
            _ = try await store.saveTopic(id: id, payload: topic)
            if let primaryAreaId { _ = try await store.relateTopic(id, to: primaryAreaId, role: .primary) }
            model.noteLocalMutation()
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
