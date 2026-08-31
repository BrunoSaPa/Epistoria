import Foundation

public struct AreaPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.area
    public var schemaVersion = "area/v1"
    public var name: String
    public var areaDescription: String?
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, areaDescription: String? = nil, now: Date = .now) {
        self.name = name
        self.areaDescription = areaDescription
        archivedAt = nil
        createdAt = now
        updatedAt = now
    }
}

/// One subject inside the notebook. Academic information is optional text metadata rather than
/// a second hierarchy of institutions and terms.
public struct TopicPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.topic
    public var schemaVersion = "topic/v1"
    public var primaryAreaId: UUID?
    public var name: String
    public var institution: String?
    public var term: String?
    public var officialClassName: String?
    public var code: String?
    public var professor: String?
    public var topicDescription: String?
    public var startDate: Date?
    public var endDate: Date?
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        name: String,
        primaryAreaId: UUID? = nil,
        institution: String? = nil,
        term: String? = nil,
        officialClassName: String? = nil,
        code: String? = nil,
        professor: String? = nil,
        now: Date = .now
    ) {
        self.primaryAreaId = primaryAreaId
        self.name = name
        self.institution = institution
        self.term = term
        self.officialClassName = officialClassName
        self.code = code
        self.professor = professor
        topicDescription = nil
        startDate = nil
        endDate = nil
        archived = false
        createdAt = now
        updatedAt = now
    }

}

public enum TopicAreaRole: String, Codable, Sendable {
    case primary = "PRIMARY"
    case related = "RELATED"
}

public struct TopicAreaRelationPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.topicArea
    public var schemaVersion = "topic-area/v1"
    public var topicId: UUID
    public var areaId: UUID
    public var role: TopicAreaRole
    public var createdAt: Date
    public var updatedAt: Date

    public init(topicId: UUID, areaId: UUID, role: TopicAreaRole, now: Date = .now) {
        self.topicId = topicId
        self.areaId = areaId
        self.role = role
        createdAt = now
        updatedAt = now
    }
}
