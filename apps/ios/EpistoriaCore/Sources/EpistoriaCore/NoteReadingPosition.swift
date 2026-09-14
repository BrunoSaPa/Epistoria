import Foundation

public enum NotePageFitMode: String, Codable, Sendable {
    case width
    case page
}

/// Device-local presentation state, not an entity or a synchronized mutation.
public struct NoteReadingPosition: Codable, Equatable, Sendable {
    public var pageId: UUID
    public var fraction: Double
    public var recordedAt: Date
    public var fitMode: NotePageFitMode

    public init(pageId: UUID, fraction: Double, recordedAt: Date = .now, fitMode: NotePageFitMode = .width) {
        self.pageId = pageId
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        self.recordedAt = recordedAt
        self.fitMode = fitMode
    }

    private enum CodingKeys: String, CodingKey { case pageId, fraction, recordedAt, fitMode }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pageId = try values.decode(UUID.self, forKey: .pageId)
        fraction = try values.decode(Double.self, forKey: .fraction)
        recordedAt = try values.decode(Date.self, forKey: .recordedAt)
        // Existing device-local reading positions predate fit controls; keep their view at width.
        fitMode = try values.decodeIfPresent(NotePageFitMode.self, forKey: .fitMode) ?? .width
    }
}
