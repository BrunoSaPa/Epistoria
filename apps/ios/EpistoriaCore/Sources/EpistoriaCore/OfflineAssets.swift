import Foundation

public struct OfflineAssetItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let encryptedByteSize: Int64
    public let isAvailable: Bool

    public init(id: UUID, filename: String, encryptedByteSize: Int64, isAvailable: Bool) {
        self.id = id
        self.filename = filename
        self.encryptedByteSize = encryptedByteSize
        self.isAvailable = isAvailable
    }
}

public struct OfflineDownloadEstimate: Equatable, Sendable {
    public let fileCount: Int
    public let downloadBytes: Int64
    public let requiredFreeBytes: Int64

    /// Reserve room for atomic file replacement and ordinary database writes. The estimate
    /// counts immutable assets once, even when several Sources or note objects reference them.
    public init(items: [OfflineAssetItem], selectedIDs: Set<UUID>) throws {
        var seen = Set<UUID>()
        var total: Int64 = 0
        var largest: Int64 = 0
        for item in items where selectedIDs.contains(item.id) && !item.isAvailable {
            guard seen.insert(item.id).inserted else { continue }
            guard item.encryptedByteSize > 0, item.encryptedByteSize <= 536_870_912 else {
                throw AssetManagerError.fileTooLarge
            }
            let (sum, overflow) = total.addingReportingOverflow(item.encryptedByteSize)
            guard !overflow else { throw AssetManagerError.fileTooLarge }
            total = sum
            largest = max(largest, item.encryptedByteSize)
        }
        let (required, overflow) = total.addingReportingOverflow(largest + 16 * 1_024 * 1_024)
        guard !overflow else { throw AssetManagerError.fileTooLarge }
        fileCount = seen.count
        downloadBytes = total
        requiredFreeBytes = seen.isEmpty ? 0 : required
    }
}
