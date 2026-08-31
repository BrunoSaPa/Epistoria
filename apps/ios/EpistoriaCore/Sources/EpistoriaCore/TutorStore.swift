import Foundation

public extension EpistoriaStore {
    @discardableResult
    func createTutorSession(
        topicId: UUID,
        studySessionId: UUID? = nil,
        goalId: UUID? = nil,
        objective: String? = nil,
        timeTargetMinutes: Int? = nil,
        sourceVersionIds: [UUID] = [],
        includeConnectedKnowledge: Bool = false,
        guidanceStyle: TutorGuidanceStyle = .adaptive,
        providerRoute: AIProviderRouteSnapshot? = nil,
        budget: TutorSessionBudget = TutorSessionBudget(),
        now: Date = .now
    ) async throws -> UUID {
        _ = try await topic(id: topicId)
        if let studySessionId {
            let session = try await payload(StudySessionPayload.self, id: studySessionId)
            guard session.payload.topicId == topicId else { throw StoreError.sessionTopicRequired }
        }
        if let goalId {
            let goal = try await payload(StudyGoalPayload.self, id: goalId)
            guard goal.payload.topicId == topicId else { throw StoreError.relationshipNotFound }
        }
        let versions = try await list(SourceVersionPayload.self)
        let allowedVersionIds = Set(versions.filter { version in
            guard sourceVersionIds.contains(version.id) else { return false }
            return true
        }.map(\.id))
        guard allowedVersionIds.count == Set(sourceVersionIds).count else {
            throw StoreError.relationshipNotFound
        }
        let payload = TutorSessionPayload(
            topicId: topicId,
            studySessionId: studySessionId,
            goalId: goalId,
            objective: objective,
            timeTargetMinutes: timeTargetMinutes,
            sourceVersionIds: sourceVersionIds,
            includeConnectedKnowledge: includeConnectedKnowledge,
            guidanceStyle: guidanceStyle,
            providerRoute: providerRoute,
            budget: budget,
            now: now
        )
        let id = UUID()
        _ = try await save(
            id: id,
            payload: payload,
            parentId: topicId,
            relationIds: [topicId, studySessionId, goalId].compactMap { $0 } + sourceVersionIds
        )
        return id
    }

    func setTutorSessionState(
        id: UUID,
        state: TutorSessionState,
        at date: Date = .now
    ) async throws {
        var identified = try await payload(TutorSessionPayload.self, id: id)
        identified.payload.state = state
        identified.payload.pausedAt = state == .paused ? date : nil
        if state == .ended || state == .abandoned {
            identified.payload.endedAt = date
        }
        identified.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: identified.payload,
            parentId: identified.payload.topicId,
            relationIds: tutorSessionRelations(identified.payload)
        )
    }

    func reviewLearningSignal(
        id: UUID,
        state: LearningSignalReviewState,
        at date: Date = .now
    ) async throws {
        var identified = try await payload(LearningSignalPayload.self, id: id)
        identified.payload.reviewState = state
        identified.payload.reviewedAt = state == .proposed ? nil : date
        if state == .accepted, identified.payload.provenance == .generatedAI {
            identified.payload.provenance = .reviewedAI
        }
        identified.payload.updatedAt = date
        _ = try await save(
            id: id,
            payload: identified.payload,
            parentId: identified.payload.tutorSessionId,
            relationIds: [
                identified.payload.tutorSessionId,
                identified.payload.topicId,
            ] + identified.payload.turnIds + identified.payload.evidenceIds
        )
    }

    /// Saves learner input when no provider route is available. The turn remains durable and can
    /// be used to resume the session after a provider is configured.
    @discardableResult
    func appendOfflineTutorTurn(
        sessionId: UUID,
        text: String,
        confidence: Int? = nil,
        kind: TutorTurnKind = .reflection,
        now: Date = .now
    ) async throws -> UUID {
        let session = try await payload(TutorSessionPayload.self, id: sessionId)
        guard session.payload.state == .active else { throw StoreError.relationshipNotFound }
        let existing = try await tutorTurns(sessionId: sessionId)
        let turn = TutorTurnPayload(
            tutorSessionId: sessionId,
            sequence: (existing.map(\.payload.sequence).max() ?? -1) + 1,
            role: .learner,
            kind: kind,
            text: text,
            confidence: confidence,
            pending: true,
            now: now
        )
        let id = UUID()
        _ = try await save(
            id: id,
            payload: turn,
            parentId: sessionId,
            relationIds: [sessionId, session.payload.topicId]
        )
        return id
    }

    func resolvePendingTutorTurn(
        sessionId: UUID,
        jobId: UUID,
        statusMessage: String,
        now: Date = .now
    ) async throws {
        let session = try await payload(TutorSessionPayload.self, id: sessionId)
        let turns = try await tutorTurns(sessionId: sessionId)
        guard var pending = turns.first(where: {
            $0.payload.jobId == jobId && $0.payload.role == .learner && $0.payload.pending
        }) else { return }
        pending.payload.pending = false
        pending.payload.updatedAt = now
        _ = try await save(
            id: pending.id,
            payload: pending.payload,
            parentId: sessionId,
            relationIds: [sessionId, session.payload.topicId, jobId]
        )
        let system = TutorTurnPayload(
            tutorSessionId: sessionId,
            sequence: (turns.map(\.payload.sequence).max() ?? pending.payload.sequence) + 1,
            role: .system,
            kind: .reflection,
            text: statusMessage,
            now: now
        )
        _ = try await save(
            payload: system,
            parentId: sessionId,
            relationIds: [sessionId, session.payload.topicId, jobId]
        )
    }

    func tutorSessions(topicId: UUID? = nil) async throws -> [IdentifiedPayload<TutorSessionPayload>] {
        let sessions = try await list(TutorSessionPayload.self)
        return sessions.filter { topicId == nil || $0.payload.topicId == topicId }
            .sorted { $0.payload.updatedAt > $1.payload.updatedAt }
    }

    func tutorTurns(sessionId: UUID) async throws -> [IdentifiedPayload<TutorTurnPayload>] {
        try await list(TutorTurnPayload.self, parentId: sessionId)
            .sorted {
                if $0.payload.sequence == $1.payload.sequence {
                    return $0.payload.createdAt < $1.payload.createdAt
                }
                return $0.payload.sequence < $1.payload.sequence
            }
    }

    func learningSignals(sessionId: UUID? = nil) async throws -> [IdentifiedPayload<LearningSignalPayload>] {
        let values = try await list(LearningSignalPayload.self)
        return values.filter { sessionId == nil || $0.payload.tutorSessionId == sessionId }
            .sorted { $0.payload.createdAt > $1.payload.createdAt }
    }

    private func tutorSessionRelations(_ payload: TutorSessionPayload) -> [UUID] {
        [payload.topicId, payload.studySessionId, payload.goalId].compactMap { $0 }
            + payload.sourceVersionIds
    }
}
