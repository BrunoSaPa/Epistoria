import Foundation
import Testing
@testable import EpistoriaCore

struct SourceListLifecycleTests {
    @Test func sourceEditsAndListLinksStayConsistentWithoutChangingFrozenVersions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceList-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(url: directory.appendingPathComponent("test.sqlite"), key: Data(repeating: 4, count: 32))
        let store = EpistoriaStore(database: database)
        let list = try await store.createList(name: "Reading")
        let source = try await store.createSource(type: .pastedText, title: "Original")
        let version = try await store.payload(SourcePayload.self, id: source).payload.currentVersionId
        try await store.updateSource(id: source, title: "Renamed", primaryTopicId: nil,
            relatedTopicIds: [], listIds: [list], archived: true)
        let links = try await store.list(RelationPayload.self, parentId: list, entityTypeOverride: .listItem)
        #expect(links.count == 1)
        #expect(links.first?.payload.rightId == source)
        #expect(try await store.sourcesInList(id: list).map(\.id) == [source])
        try await store.updateList(id: list, name: "Reference", archived: true)
        try await store.updateList(id: list, name: "Reference", archived: false)
        #expect(try await store.sourceListIds(id: source) == [list])
        try await store.updateSource(id: source, title: "Renamed", primaryTopicId: nil,
            relatedTopicIds: [], listIds: [], archived: false)
        let restored = try await store.payload(SourcePayload.self, id: source)
        #expect(restored.payload.archivedAt == nil)
        #expect(restored.payload.currentVersionId == version)
        #expect(try await store.sourceListIds(id: source).isEmpty)
        #expect(try await store.list(RelationPayload.self, parentId: list, entityTypeOverride: .listItem).isEmpty)
        let deletedLink = try await database.entity(id: links[0].id)
        #expect(deletedLink?.tombstone == true)
    }

    @Test func legacyLinkOnlyMembershipIsPreservedWhenRenaming() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LegacySourceList-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(url: directory.appendingPathComponent("test.sqlite"), key: Data(repeating: 4, count: 32))
        let store = EpistoriaStore(database: database)
        let list = try await store.createList(name: "Reading")
        let source = try await store.createSource(type: .pastedText, title: "Original")
        _ = try await store.save(payload: RelationPayload(kind: .listItem, leftId: list, rightId: source),
            parentId: list, relationIds: [list, source], entityTypeOverride: .listItem)
        let memberships = try await store.sourceListIds(id: source)
        #expect(memberships == [list])
        try await store.updateSource(id: source, title: "Updated", primaryTopicId: nil,
            relatedTopicIds: [], listIds: Array(memberships), archived: false)
        #expect(try await store.sourcesInList(id: list).map(\.id) == [source])
        #expect(try await store.list(RelationPayload.self, parentId: list, entityTypeOverride: .listItem).count == 1)
    }
}
