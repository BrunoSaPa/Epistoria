import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImportedResource: Equatable, Sendable {
    public var resourceId: UUID
    public var assetId: UUID
    public var reusedExistingAsset: Bool
}

public struct ImportedImage: Equatable, Sendable {
    public var assetId: UUID
    public var reusedExistingAsset: Bool
    public var filename: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        assetId: UUID,
        reusedExistingAsset: Bool,
        filename: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.assetId = assetId
        self.reusedExistingAsset = reusedExistingAsset
        self.filename = filename
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum AssetManagerError: Error, Equatable, LocalizedError {
    case notPDF
    case notImage
    case fileTooLarge
    case imageDimensionsTooLarge
    case encryptedAssetUnavailable
    case assetMetadataUnavailable
    case encryptedAssetSizeMismatch
    case assetIntegrityMismatch

    public var errorDescription: String? {
        switch self {
        case .notPDF: "The selected file is not a valid PDF."
        case .notImage: "The selected file is not a supported image."
        case .fileTooLarge: "The selected file is too large to import safely."
        case .imageDimensionsTooLarge: "The image dimensions are too large to render safely."
        case .encryptedAssetUnavailable: "The encrypted original is not available on this device."
        case .assetMetadataUnavailable: "The encrypted asset metadata is unavailable."
        case .encryptedAssetSizeMismatch: "The downloaded encrypted asset has the wrong size."
        case .assetIntegrityMismatch: "The encrypted asset did not pass its integrity check."
        }
    }
}

public actor AssetManager {
    private let accountId: UUID
    private let accountKey: Data
    private let store: EpistoriaStore
    private let database: SQLCipherDatabase
    private let directory: URL
    private var api: EpistoriaAPIClient?
    private let crypto = EntityCrypto()
    private let assetCrypto = AssetCrypto()

    public init(
        accountId: UUID,
        accountKey: Data,
        store: EpistoriaStore,
        directory: URL,
        api: EpistoriaAPIClient? = nil
    ) {
        self.accountId = accountId
        self.accountKey = accountKey
        self.store = store
        database = store.database
        self.directory = directory
        self.api = api
    }

    public func setAPIClient(_ api: EpistoriaAPIClient?) {
        self.api = api
    }

    public func importPDF(
        from sourceURL: URL,
        courseId: UUID? = nil,
        sessionId: UUID? = nil
    ) async throws -> ImportedResource {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AssetManagerError.notPDF }
        if let size = values.fileSize, size > 512 * 1_024 * 1_024 {
            throw AssetManagerError.fileTooLarge
        }
        let plaintext = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard plaintext.starts(with: Data("%PDF-".utf8)) else {
            throw AssetManagerError.notPDF
        }
        guard plaintext.count <= 512 * 1024 * 1024 else {
            throw AssetManagerError.fileTooLarge
        }
        let imported = try await importAsset(
            plaintext: plaintext,
            mimeType: "application/pdf",
            originalFilename: sourceURL.lastPathComponent
        )
        let resourceId = try await createResource(
            title: sourceURL.deletingPathExtension().lastPathComponent,
            assetId: imported.assetId,
            courseId: courseId,
            sessionId: sessionId
        )
        return ImportedResource(
            resourceId: resourceId,
            assetId: imported.assetId,
            reusedExistingAsset: imported.reusedExistingAsset
        )
    }

    /// Imports original image bytes as an encrypted immutable asset without creating a Library
    /// resource. A spatial note item references the returned asset ID. ImageIO validates that
    /// the input is decodable before any encrypted file or metadata record is created.
    public func importImage(from sourceURL: URL) async throws -> ImportedImage {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AssetManagerError.notImage }
        if let size = values.fileSize, size > 64 * 1_024 * 1_024 {
            throw AssetManagerError.fileTooLarge
        }
        let plaintext = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard plaintext.count <= 64 * 1_024 * 1_024 else {
            throw AssetManagerError.fileTooLarge
        }
        guard let source = CGImageSourceCreateWithData(plaintext as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let pixelWidth = integer(properties[kCGImagePropertyPixelWidth]),
              let pixelHeight = integer(properties[kCGImagePropertyPixelHeight]),
              pixelWidth > 0,
              pixelHeight > 0
        else { throw AssetManagerError.notImage }
        guard pixelWidth <= 32_768,
              pixelHeight <= 32_768,
              Int64(pixelWidth) * Int64(pixelHeight) <= 100_000_000
        else { throw AssetManagerError.imageDimensionsTooLarge }

        let typeIdentifier = CGImageSourceGetType(source) as String?
        let mimeType = typeIdentifier
            .flatMap(UTType.init)
            .flatMap(\.preferredMIMEType) ?? "image/unknown"
        let filename = sourceURL.lastPathComponent.isEmpty
            ? "Imported image"
            : sourceURL.lastPathComponent
        let imported = try await importAsset(
            plaintext: plaintext,
            mimeType: mimeType,
            originalFilename: filename
        )
        return ImportedImage(
            assetId: imported.assetId,
            reusedExistingAsset: imported.reusedExistingAsset,
            filename: filename,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    public func decryptedData(assetId: UUID) async throws -> Data {
        let metadata = try await assetMetadata(id: assetId)
        let local: LocalAsset
        if let cached = try await usableLocalAsset(id: assetId, metadata: metadata.payload) {
            local = cached
        } else {
            local = try await cacheAsset(assetId: assetId, metadata: metadata.payload)
        }
        let encrypted = try Data(contentsOf: local.encryptedFileURL, options: .mappedIfSafe)
        return try verifiedPlaintext(encrypted: encrypted, metadata: metadata.payload)
    }

    @discardableResult
    public func cacheAsset(assetId: UUID) async throws -> LocalAsset {
        let metadata = try await assetMetadata(id: assetId)
        if let cached = try await usableLocalAsset(id: assetId, metadata: metadata.payload) {
            return cached
        }
        return try await cacheAsset(assetId: assetId, metadata: metadata.payload)
    }

    private func cacheAsset(assetId: UUID, metadata: AssetPayload) async throws -> LocalAsset {
        guard let api else { throw AssetManagerError.encryptedAssetUnavailable }
        guard metadata.encryptedByteSize > 0,
              metadata.encryptedByteSize <= 536_870_912,
              let maximumBytes = Int(exactly: metadata.encryptedByteSize)
        else { throw AssetManagerError.fileTooLarge }
        let encrypted = try await api.downloadAsset(id: assetId, maximumBytes: maximumBytes)
        guard Int64(encrypted.count) == metadata.encryptedByteSize else {
            throw AssetManagerError.encryptedAssetSizeMismatch
        }
        _ = try verifiedPlaintext(encrypted: encrypted, metadata: metadata)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let destination = directory
            .appendingPathComponent("\(assetId.uuidString.lowercased()).epistoria")
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
        var writeOptions: Data.WritingOptions = [.atomic]
        #if os(iOS)
        writeOptions.insert(.completeFileProtection)
        #endif
        try encrypted.write(to: destination, options: writeOptions)
        let local = LocalAsset(
            id: assetId,
            dedupeTag: metadata.dedupeTag,
            encryptedFileURL: destination,
            encryptedByteSize: metadata.encryptedByteSize,
            uploadState: .available,
            lastErrorCode: nil
        )
        do {
            try await database.registerLocalAsset(local)
        } catch {
            if !destinationExisted {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
        return local
    }

    private func assetMetadata(id: UUID) async throws -> IdentifiedPayload<AssetPayload> {
        do {
            return try await store.payload(AssetPayload.self, id: id)
        } catch {
            throw AssetManagerError.assetMetadataUnavailable
        }
    }

    private func usableLocalAsset(
        id: UUID,
        metadata: AssetPayload
    ) async throws -> LocalAsset? {
        guard let local = try await database.localAsset(id: id),
              local.dedupeTag == metadata.dedupeTag,
              local.encryptedByteSize == metadata.encryptedByteSize,
              FileManager.default.fileExists(atPath: local.encryptedFileURL.path),
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: local.encryptedFileURL.path
              ),
              let size = attributes[.size] as? NSNumber,
              size.int64Value == metadata.encryptedByteSize
        else { return nil }
        return local
    }

    private func verifiedPlaintext(encrypted: Data, metadata: AssetPayload) throws -> Data {
        do {
            let key = try Base64URL.decode(metadata.assetKey)
            let plaintext = try assetCrypto.decrypt(encrypted, key: key)
            guard Int64(plaintext.count) == metadata.plaintextByteSize,
                  try crypto.dedupeTag(
                      plaintext: plaintext,
                      accountKey: accountKey,
                      accountId: accountId
                  ) == metadata.dedupeTag
            else { throw AssetManagerError.assetIntegrityMismatch }
            return plaintext
        } catch let error as AssetManagerError {
            throw error
        } catch {
            throw AssetManagerError.assetIntegrityMismatch
        }
    }

    private struct ImportedAsset {
        var assetId: UUID
        var reusedExistingAsset: Bool
    }

    private func importAsset(
        plaintext: Data,
        mimeType: String,
        originalFilename: String
    ) async throws -> ImportedAsset {
        let dedupeTag = try crypto.dedupeTag(
            plaintext: plaintext,
            accountKey: accountKey,
            accountId: accountId
        )
        if let existing = try await database.localAsset(dedupeTag: dedupeTag) {
            return ImportedAsset(assetId: existing.id, reusedExistingAsset: true)
        }

        let assetId = UUID()
        let key = try crypto.randomKey()
        let encrypted = try assetCrypto.encrypt(plaintext, key: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encryptedURL = directory.appendingPathComponent(
            "\(assetId.uuidString.lowercased()).epistoria"
        )
        var writeOptions: Data.WritingOptions = [.atomic]
        #if os(iOS)
        writeOptions.insert(.completeFileProtection)
        #endif
        try encrypted.write(to: encryptedURL, options: writeOptions)
        let local = LocalAsset(
            id: assetId,
            dedupeTag: dedupeTag,
            encryptedFileURL: encryptedURL,
            encryptedByteSize: Int64(encrypted.count),
            uploadState: .pending,
            lastErrorCode: nil
        )
        do {
            try await database.registerLocalAsset(local)
            let metadata = AssetPayload(
                mimeType: mimeType,
                plaintextByteSize: Int64(plaintext.count),
                encryptedByteSize: Int64(encrypted.count),
                dedupeTag: dedupeTag,
                assetKey: Base64URL.encode(key),
                originalFilename: originalFilename
            )
            _ = try await store.save(id: assetId, payload: metadata)
        } catch {
            try? await database.unregisterLocalAsset(id: assetId)
            try? FileManager.default.removeItem(at: encryptedURL)
            throw error
        }
        return ImportedAsset(assetId: assetId, reusedExistingAsset: false)
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private func createResource(
        title: String,
        assetId: UUID,
        courseId: UUID?,
        sessionId: UUID?
    ) async throws -> UUID {
        let resourceId = try await store.save(
            payload: ResourcePayload(
                resourceType: .pdf,
                title: title.isEmpty ? "Imported PDF" : title,
                originalAssetId: assetId
            ),
            parentId: courseId,
            relationIds: [assetId, courseId, sessionId].compactMap(\.self)
        )
        if let sessionId {
            let relation = RelationPayload(
                kind: .sessionResource,
                leftId: sessionId,
                rightId: resourceId
            )
            _ = try await store.save(
                payload: relation,
                parentId: sessionId,
                relationIds: [sessionId, resourceId],
                entityTypeOverride: .sessionResource
            )
        }
        return resourceId
    }
}
