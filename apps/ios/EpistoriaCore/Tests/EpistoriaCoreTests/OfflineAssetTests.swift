import Foundation
import Testing
@testable import EpistoriaCore

struct OfflineAssetTests {
    @Test func estimateCountsOnlyUniqueMissingSelection() throws {
        let missing = OfflineAssetItem(id: UUID(), filename: "scan.pdf", encryptedByteSize: 100, isAvailable: false)
        let cached = OfflineAssetItem(id: UUID(), filename: "image.png", encryptedByteSize: 200, isAvailable: true)
        let ignored = OfflineAssetItem(id: UUID(), filename: "other.pdf", encryptedByteSize: 300, isAvailable: false)
        let estimate = try OfflineDownloadEstimate(items: [missing, missing, cached, ignored],
            selectedIDs: [missing.id, cached.id])
        #expect(estimate.fileCount == 1)
        #expect(estimate.downloadBytes == 100)
        #expect(estimate.requiredFreeBytes == 200 + 16 * 1_024 * 1_024)
        #expect(try OfflineDownloadEstimate(items: [cached], selectedIDs: [cached.id]).requiredFreeBytes == 0)
    }

    @Test(arguments: [Int64(-1), 0, 536_870_913, Int64.max])
    func invalidSizesFailBeforeDownload(size: Int64) {
        let item = OfflineAssetItem(id: UUID(), filename: "invalid", encryptedByteSize: size, isAvailable: false)
        #expect(throws: AssetManagerError.fileTooLarge) {
            try OfflineDownloadEstimate(items: [item], selectedIDs: [item.id])
        }
    }

    @Test func inventoryPaginatesAndDetectsMissingOrTruncatedLocalFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineInventory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLCipherDatabase(url: directory.appendingPathComponent("test.sqlite"), key: Data(repeating: 4, count: 32))
        let store = EpistoriaStore(database: database)
        let manager = AssetManager(accountId: UUID(), accountKey: Data(repeating: 5, count: 32),
            store: store, directory: directory.appendingPathComponent("assets"))
        var firstID: UUID?
        for index in 0..<105 {
            let id = try await store.save(payload: AssetPayload(mimeType: "image/png", plaintextByteSize: 10,
                encryptedByteSize: 20, dedupeTag: "synthetic-\(index)", assetKey: "synthetic",
                originalFilename: "image-\(index).png"))
            if index == 0 { firstID = id }
        }
        let id = try #require(firstID)
        let file = directory.appendingPathComponent("synthetic.encrypted")
        try Data(repeating: 0, count: 20).write(to: file)
        try await database.registerLocalAsset(LocalAsset(id: id, dedupeTag: "synthetic-0",
            encryptedFileURL: file, encryptedByteSize: 20, uploadState: .available, lastErrorCode: nil))
        let before = try await database.pendingMutations(limit: 200).count
        let items = try await manager.offlineAssetInventory()
        #expect(items.count == 105)
        #expect(items.filter(\.isAvailable).map(\.id) == [id])
        try Data(repeating: 0, count: 3).write(to: file)
        #expect(try await manager.offlineAssetInventory().allSatisfy { !$0.isAvailable })
        #expect(try await database.pendingMutations(limit: 200).count == before)
        let metadata = try await store.payload(AssetPayload.self, id: id).payload
        try await database.deleteLocal(id: id)
        await #expect(throws: AssetManagerError.assetMetadataUnavailable) {
            try await database.registerLocalAsset(LocalAsset(id: id, dedupeTag: "synthetic-0",
                encryptedFileURL: file, encryptedByteSize: 20, uploadState: .available, lastErrorCode: nil),
                requiring: metadata)
        }
        await #expect(throws: AssetManagerError.assetMetadataUnavailable) {
            try await manager.cacheAsset(assetId: id)
        }
        #expect(try await manager.offlineAssetInventory().count == 104)
    }
}
