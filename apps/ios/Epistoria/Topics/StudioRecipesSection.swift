import EpistoriaCore
import SwiftUI

struct StudioRecipesSection: View {
    let store: EpistoriaStore?
    let current: StudioRecipePayload
    let onApply: (StudioRecipePayload) -> Void
    let onMutation: () -> Void
    @State private var recipes: [IdentifiedPayload<StudioRecipePayload>] = []
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var hasMore = false
    @State private var cursor: EntityPageCursor?
    @State private var showArchived = false

    var body: some View {
        Section {
            DisclosureGroup("Saved recipes") {
                Text("Reuse request settings. Review this Topic’s sources, provider and cost before each run.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show archived recipes", isOn: $showArchived)
                ForEach(recipes.filter { showArchived || !$0.payload.archived }, id: \.id) { item in
                    HStack {
                        Button(item.payload.name) { onApply(item.payload) }
                            .disabled(item.payload.archived)
                        Spacer()
                        Button(item.payload.archived ? "Restore" : "Archive", systemImage: "archivebox") {
                            Task { await archive(item) }
                        }.labelStyle(.iconOnly)
                            .accessibilityLabel("\(item.payload.archived ? "Restore" : "Archive") recipe \(item.payload.name)")
                    }
                    .buttonStyle(.borderless)
                }
                if hasMore { Button("Load more recipes") { Task { await loadMore() } } }
                TextField("Recipe name", text: $name)
                Button("Save current settings") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView() }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry loading recipes") { Task { await reload() } }
                }
            }
        }
        .disabled(busy || store == nil)
        .task { await reload() }
    }

    private func reload() async {
        recipes = []; cursor = nil
        await loadMore()
    }

    private func loadMore() async {
        guard let store else { return }
        busy = true
        defer { busy = false }
        do {
            let page = try await store.listPage(StudioRecipePayload.self,
                parentId: StudioRecipePayload.namespace, limit: 30, after: cursor)
            recipes += page.items
            cursor = page.nextCursor
            hasMore = cursor != nil
            error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard let store else { return }
        busy = true
        defer { busy = false }
        do {
            var recipe = current
            recipe.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try await store.saveStudioRecipe(recipe)
            onMutation(); name = ""
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func archive(_ item: IdentifiedPayload<StudioRecipePayload>) async {
        guard let store else { return }
        busy = true
        defer { busy = false }
        do {
            var recipe = item.payload
            recipe.archived.toggle(); recipe.updatedAt = .now
            try await store.saveStudioRecipe(recipe, id: item.id)
            onMutation()
            if let index = recipes.firstIndex(where: { $0.id == item.id }) { recipes[index].payload = recipe }
        } catch { self.error = error.localizedDescription }
    }
}
