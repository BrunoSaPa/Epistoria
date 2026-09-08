import Foundation

/// Owner-authored settings carried by the existing encrypted Studio transport, not AI output.
/// Scope, provider, credentials, approval and generated content are deliberately absent.
public struct StudioRecipePayload: EntityPayload, Equatable {
    public static let entityType = EntityType.aiArtifact
    public static let namespace = UUID(uuidString: "831F0CC1-FA25-4A87-A9B3-CF88912B7B03")!
    public var schemaVersion = "studio-recipe/v1"
    public var name: String
    public var jobType: LearningAIJobType
    public var instructions: String
    public var testMode: TestMode
    public var questionCount: Int
    public var timeLimitMinutes: Int?
    public var coverage: [TestCoverageDimension]
    public var archived = false
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, jobType: LearningAIJobType, instructions: String,
                testMode: TestMode = .comprehensive, questionCount: Int = 12,
                timeLimitMinutes: Int? = nil, coverage: [TestCoverageDimension] = TestCoverageDimension.allCases) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.jobType = jobType
        self.instructions = instructions
        self.testMode = testMode
        self.questionCount = questionCount
        self.timeLimitMinutes = timeLimitMinutes
        self.coverage = coverage
        createdAt = .now
        updatedAt = createdAt
    }

    public func validate() throws {
        guard schemaVersion == "studio-recipe/v1", !name.isEmpty, name.count <= 120,
              instructions.count <= 16_000, (1...100).contains(questionCount),
              timeLimitMinutes.map({ (5...600).contains($0) }) ?? true,
              [.topicSynthesis, .flashcardDrafts, .testBlueprint, .testGeneration,
               .conceptSuggestions, .weeklyReview].contains(jobType),
              !coverage.isEmpty, Set(coverage).count == coverage.count
        else { throw ValidationError.invalidRecipe }
    }

    public enum ValidationError: Error, LocalizedError {
        case invalidRecipe
        public var errorDescription: String? {
            "Use a name up to 120 characters, instructions up to 16,000 characters and valid output settings."
        }
    }
}

public extension EpistoriaStore {
    func saveStudioRecipe(_ recipe: StudioRecipePayload, id: UUID = UUID()) async throws {
        try recipe.validate()
        _ = try await save(id: id, payload: recipe, parentId: StudioRecipePayload.namespace)
    }
}
