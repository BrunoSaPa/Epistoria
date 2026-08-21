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

/// User-facing replacement for `CoursePayload`. The encrypted transport discriminator remains
/// `COURSE`, so existing IDs, links, sync envelopes, and restored backups remain valid.
public struct TopicPayload: EntityPayload, Equatable {
    public static let entityType = EntityType.course
    public var schemaVersion: String
    public var primaryAreaId: UUID?
    public var institutionId: UUID?
    public var academicTermId: UUID?
    public var name: String
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
        institutionId: UUID? = nil,
        academicTermId: UUID? = nil,
        officialClassName: String? = nil,
        code: String? = nil,
        professor: String? = nil,
        now: Date = .now
    ) {
        schemaVersion = "topic/v1"
        self.primaryAreaId = primaryAreaId
        self.institutionId = institutionId
        self.academicTermId = academicTermId
        self.name = name
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, primaryAreaId, institutionId, academicTermId, name
        case officialClassName, code, professor, topicDescription, courseDescription
        case startDate, endDate, archived, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try values.decodeIfPresent(String.self, forKey: .schemaVersion)
            ?? "course/v1"
        guard decodedSchema == "course/v1" || decodedSchema == "topic/v1" else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported Topic schema \(decodedSchema)"
            )
        }
        schemaVersion = decodedSchema
        primaryAreaId = try values.decodeIfPresent(UUID.self, forKey: .primaryAreaId)
        institutionId = try values.decodeIfPresent(UUID.self, forKey: .institutionId)
        academicTermId = try values.decodeIfPresent(UUID.self, forKey: .academicTermId)
        name = try values.decode(String.self, forKey: .name)
        officialClassName = try values.decodeIfPresent(String.self, forKey: .officialClassName)
        code = try values.decodeIfPresent(String.self, forKey: .code)
        professor = try values.decodeIfPresent(String.self, forKey: .professor)
        topicDescription = try values.decodeIfPresent(String.self, forKey: .topicDescription)
            ?? values.decodeIfPresent(String.self, forKey: .courseDescription)
        startDate = try values.decodeIfPresent(Date.self, forKey: .startDate)
        endDate = try values.decodeIfPresent(Date.self, forKey: .endDate)
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("topic/v1", forKey: .schemaVersion)
        try values.encodeIfPresent(primaryAreaId, forKey: .primaryAreaId)
        try values.encodeIfPresent(institutionId, forKey: .institutionId)
        try values.encodeIfPresent(academicTermId, forKey: .academicTermId)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(officialClassName, forKey: .officialClassName)
        try values.encodeIfPresent(code, forKey: .code)
        try values.encodeIfPresent(professor, forKey: .professor)
        try values.encodeIfPresent(topicDescription, forKey: .topicDescription)
        try values.encodeIfPresent(startDate, forKey: .startDate)
        try values.encodeIfPresent(endDate, forKey: .endDate)
        try values.encode(archived, forKey: .archived)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
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

public struct TaxonomyMigrationJournal: Codable, Equatable, Sendable {
    public var schemaVersion = "taxonomy-migration-journal/v1"
    public var migrationId: UUID
    public var startedAt: Date
    public var completedAt: Date?
    public var upgradedTopicIds: [UUID]
    public var verifiedTopicIds: [UUID]
    public var failure: String?

    public init(migrationId: UUID = UUID(), now: Date = .now) {
        self.migrationId = migrationId
        startedAt = now
        completedAt = nil
        upgradedTopicIds = []
        verifiedTopicIds = []
        failure = nil
    }
}
