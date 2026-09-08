import Foundation
import Testing
@testable import EpistoriaCore

struct StudioRecipeTests {
    @Test func settingsRoundTripWithoutAuthorizationOrScope() throws {
        var recipe = StudioRecipePayload(name: "Practice", jobType: .testGeneration,
            instructions: "Explain mistakes", testMode: .custom, questionCount: 8,
            timeLimitMinutes: 25, coverage: [.conceptual, .verification])
        recipe.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        recipe.updatedAt = recipe.createdAt
        let data = try CanonicalJSON.encode(recipe)
        #expect(try CanonicalJSON.decode(StudioRecipePayload.self, from: data) == recipe)
        try EntityPayloadValidator.validate(entityType: .aiArtifact, content: data)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for forbidden in ["provider", "providerRoute", "approval", "apiKey", "sourceIds", "topicId", "includeConnectedKnowledge"] {
            #expect(json[forbidden] == nil)
        }
        var invalid = recipe
        invalid.questionCount = 0
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(throws: (any Error).self) {
            try EntityPayloadValidator.validate(entityType: .aiArtifact, content: CanonicalJSON.encode(invalid))
        }
    }

    @Test func settingsPersistAndArchiveUsingNormalStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecipeTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(url: directory.appendingPathComponent("test.sqlite"), key: Data(repeating: 9, count: 32))
        let store = EpistoriaStore(database: database)
        let id = UUID()
        var recipe = StudioRecipePayload(name: "Summary", jobType: .topicSynthesis, instructions: "Be brief")
        recipe.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        recipe.updatedAt = recipe.createdAt
        try await store.saveStudioRecipe(recipe, id: id)
        let saved = try await store.listPage(StudioRecipePayload.self, parentId: StudioRecipePayload.namespace, limit: 1)
        #expect(saved.items.first?.id == id)
        #expect(saved.items.first?.payload == recipe)
        recipe.archived = true
        try await store.saveStudioRecipe(recipe, id: id)
        #expect(try await store.payload(StudioRecipePayload.self, id: id).payload.archived)
    }
}
