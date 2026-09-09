import Foundation

/// Device-local presentation state, not an entity or a synchronized mutation.
public struct NoteReadingPosition: Codable, Equatable, Sendable {
    public var pageId: UUID
    public var fraction: Double
    public var recordedAt: Date

    public init(pageId: UUID, fraction: Double, recordedAt: Date = .now) {
        self.pageId = pageId
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        self.recordedAt = recordedAt
    }
}
