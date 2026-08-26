import EpistoriaCore
import SwiftUI

private enum ConflictResolutionProblem: LocalizedError {
    case serverRequired
    case syncFailed(String)
    case currentVersionUnavailable
    case replacementIdentityCollision

    var errorDescription: String? {
        switch self {
        case .serverRequired: "Reconnect the private sync server before resolving this conflict."
        case let .syncFailed(message): "The conflict copy is safe locally, but server resolution must wait: \(message)"
        case .currentVersionUnavailable: "The current synced version is unavailable on this device. Sync and try again."
        case .replacementIdentityCollision: "The preserved-copy identifier is already used by different local content. Nothing was overwritten."
        }
    }
}

private struct PendingConflictResolution: Identifiable {
    enum Choice { case keepCurrent, preserveBoth }
    let conflict: LocalConflict
    let choice: Choice
    var id: String { "\(conflict.id)-\(choice)" }
}

struct ConflictResolutionView: View {
    @Bindable var model: AppModel
    let onChanged: () -> Void

    @State private var conflicts: [LocalConflict] = []
    @State private var current: [UUID: StoredEntity] = [:]
    @State private var pending: PendingConflictResolution?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if conflicts.isEmpty {
                ContentUnavailableView(
                    "No unresolved conflicts",
                    systemImage: "checkmark.circle",
                    description: Text("Epistoria has no preserved alternate versions waiting for a decision.")
                )
            } else {
                List {
                    ForEach(conflicts) { conflict in
                        Section {
                            comparison(conflict)
                            HStack {
                                Button("Keep synced version", role: .destructive) {
                                    pending = PendingConflictResolution(
                                        conflict: conflict,
                                        choice: .keepCurrent
                                    )
                                }
                                Button("Preserve both") {
                                    pending = PendingConflictResolution(
                                        conflict: conflict,
                                        choice: .preserveBoth
                                    )
                                }
                                .disabled(conflict.entityType == .asset)
                            }
                            .disabled(isWorking)
                        } header: {
                            Text("\(typeLabel(conflict.entityType)) · \(conflict.createdAt.formatted())")
                        } footer: {
                            if conflict.entityType == .asset {
                                Text("Binary asset conflicts cannot be copied as metadata-only records. The encrypted original remains in the asset store.")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sync conflicts")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            pending?.choice == .preserveBoth ? "Preserve both versions?" : "Keep the synced version?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { action in
            switch action.choice {
            case .keepCurrent:
                Button("Keep synced version", role: .destructive) {
                    Task { await resolve(action.conflict, preserveBoth: false) }
                }
            case .preserveBoth:
                Button("Create conflict copy") {
                    Task { await resolve(action.conflict, preserveBoth: true) }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(
                action.choice == .preserveBoth
                    ? "Your alternate version becomes a new encrypted record, syncs, and remains searchable."
                    : "The alternate version is marked resolved. Choose Preserve both if you are uncertain."
            )
        }
        .alert("Conflict resolution error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func comparison(_ conflict: LocalConflict) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Synced version", systemImage: "cloud")
                    .font(.headline)
                Text(current[conflict.entityId].map { summary($0.content, type: $0.entityType) } ?? "Unavailable")
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("Your preserved version", systemImage: "ipad")
                    .font(.headline)
                Text(summary(conflict.candidateContent, type: conflict.entityType))
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let database = model.database else { return }
        do {
            let loaded = try await database.conflicts()
            var entities: [UUID: StoredEntity] = [:]
            for conflict in loaded {
                if let entity = try await database.entity(id: conflict.entityId) {
                    entities[conflict.entityId] = entity
                }
            }
            conflicts = loaded
            current = entities
        } catch { errorMessage = error.localizedDescription }
    }

    private func resolve(_ conflict: LocalConflict, preserveBoth: Bool) async {
        guard let database = model.database else { return }
        isWorking = true
        pending = nil
        defer { isWorking = false }
        do {
            let replacementId: UUID
            if preserveBoth {
                // Derive the replacement identity from the durable server conflict whenever
                // available. Retries—even after rehydration on another install—therefore
                // reuse one copy instead of creating duplicate conflict copies.
                replacementId = conflict.serverConflictId ?? conflict.id
                if let existing = try await database.entity(id: replacementId) {
                    guard !existing.tombstone,
                          existing.entityType == conflict.entityType,
                          existing.parentId == conflict.parentId,
                          existing.relationIds == conflict.relationIds,
                          existing.content == conflict.candidateContent
                    else { throw ConflictResolutionProblem.replacementIdentityCollision }
                } else {
                    _ = try await database.saveLocal(
                        id: replacementId,
                        entityType: conflict.entityType,
                        parentId: conflict.parentId,
                        relationIds: conflict.relationIds,
                        content: conflict.candidateContent,
                        search: EntitySearchIndexer.document(
                            for: conflict.entityType,
                            content: conflict.candidateContent
                        )
                    )
                }
                await model.synchronize()
                if let message = model.syncError {
                    throw ConflictResolutionProblem.syncFailed(message)
                }
            } else {
                guard let entity = current[conflict.entityId], !entity.tombstone else {
                    throw ConflictResolutionProblem.currentVersionUnavailable
                }
                replacementId = entity.id
            }

            if let serverConflictId = conflict.serverConflictId {
                guard let api = model.api else { throw ConflictResolutionProblem.serverRequired }
                _ = try await api.resolveConflict(
                    id: serverConflictId,
                    replacementEntityId: replacementId
                )
            }
            try await database.resolveLocalConflict(id: conflict.id)
            await load()
            onChanged()
        } catch { errorMessage = error.localizedDescription }
    }

    private func typeLabel(_ type: EntityType) -> String {
        type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func summary(_ content: Data, type: EntityType) -> String {
        let value: String
        switch type {
        case .collection:
            value = (try? CanonicalJSON.decode(CollectionPayload.self, from: content).name) ?? "Collection"
        case .institution:
            value = (try? CanonicalJSON.decode(InstitutionPayload.self, from: content).name) ?? "Institution"
        case .academicTerm:
            value = (try? CanonicalJSON.decode(AcademicTermPayload.self, from: content).name) ?? "Academic term"
        case .course:
            value = (try? CanonicalJSON.decode(CoursePayload.self, from: content).name) ?? "Course"
        case .studySession:
            value = (try? CanonicalJSON.decode(StudySessionPayload.self, from: content).title) ?? "Study session"
        case .note:
            value = (try? CanonicalJSON.decode(NotePayload.self, from: content).title) ?? "Note"
        case .noteBlock:
            if let block = try? CanonicalJSON.decode(NoteBlockPayload.self, from: content) {
                value = block.plainText.isEmpty ? "Handwritten canvas item with original strokes" : block.plainText
            } else { value = "Notebook canvas item" }
        case .resource:
            value = (try? CanonicalJSON.decode(ResourcePayload.self, from: content).title) ?? "Resource"
        case .asset:
            value = (try? CanonicalJSON.decode(AssetPayload.self, from: content).originalFilename) ?? "Encrypted asset"
        case .annotation:
            value = (try? CanonicalJSON.decode(AnnotationPayload.self, from: content).comment) ?? "Annotation"
        case .transcriptCorrection:
            value = (try? CanonicalJSON.decode(
                TranscriptCorrectionPayload.self,
                from: content
            ).correctedText) ?? "Transcript correction"
        case .aiArtifact:
            if let digest = try? CanonicalJSON.decode(SessionDigestArtifact.self, from: content) {
                value = digest.editedDigest?.summary ?? digest.digest.summary
            } else { value = "Derived processing artifact" }
        case .collectionItem, .sessionNote, .sessionResource, .topicArea,
             .conceptEvidence, .conceptLink:
            value = "Relationship record"
        case .area:
            value = (try? CanonicalJSON.decode(AreaPayload.self, from: content).name) ?? "Area"
        case .evidence:
            value = (try? CanonicalJSON.decode(EvidencePayload.self, from: content).excerpt) ?? "Evidence"
        case .concept:
            value = (try? CanonicalJSON.decode(ConceptPayload.self, from: content).name) ?? "Concept"
        case .studyGoal:
            value = (try? CanonicalJSON.decode(StudyGoalPayload.self, from: content).title) ?? "Study goal"
        case .unresolvedQuestion:
            value = (try? CanonicalJSON.decode(UnresolvedQuestionPayload.self, from: content).question) ?? "Unresolved question"
        case .flashcardRevision:
            value = (try? CanonicalJSON.decode(FlashcardRevisionPayload.self, from: content).prompt) ?? "Flashcard revision"
        case .practiceTest:
            value = (try? CanonicalJSON.decode(PracticeTestPayload.self, from: content).title) ?? "Practice test"
        case .testQuestion:
            value = (try? CanonicalJSON.decode(TestQuestionPayload.self, from: content).prompt) ?? "Test question"
        case .studyRecommendation:
            value = (try? CanonicalJSON.decode(StudyRecommendationPayload.self, from: content).title) ?? "Study recommendation"
        case .tutorSession:
            value = (try? CanonicalJSON.decode(TutorSessionPayload.self, from: content).objective) ?? "Tutor session"
        case .tutorTurn:
            value = (try? CanonicalJSON.decode(TutorTurnPayload.self, from: content).text) ?? "Tutor turn"
        case .learningSignal:
            value = (try? CanonicalJSON.decode(LearningSignalPayload.self, from: content).objective) ?? "Learning signal"
        case .sourceVersion, .sessionActivity, .flashcardDeck, .flashcard, .flashcardReview,
             .topicScopeSnapshot, .testBlueprint, .testAttempt, .testResponse,
             .recommendationResponse, .automationGrant:
            value = typeLabel(type)
        }
        return String(value.prefix(1_000))
    }
}
