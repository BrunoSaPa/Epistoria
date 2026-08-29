import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImportedResource: Equatable, Sendable {
    public var resourceId: UUID
    public var assetId: UUID
    public var reusedExistingAsset: Bool
}

public struct RefreshedWebSnapshot: Equatable, Sendable {
    public var versionId: UUID
    public var capturedURL: URL
    public var difference: WebSnapshotDifference

    public init(versionId: UUID, capturedURL: URL, difference: WebSnapshotDifference) {
        self.versionId = versionId
        self.capturedURL = capturedURL
        self.difference = difference
    }
}

public struct RefreshedGoogleWorkspaceSnapshot: Equatable, Sendable {
    public var versionId: UUID
    public var capturedURL: URL
    public var difference: WebSnapshotDifference

    public init(versionId: UUID, capturedURL: URL, difference: WebSnapshotDifference) {
        self.versionId = versionId
        self.capturedURL = capturedURL
        self.difference = difference
    }
}

public struct ImportedYouTubeReference: Equatable, Sendable {
    public var sourceId: UUID
    public var videoID: String

    public init(sourceId: UUID, videoID: String) {
        self.sourceId = sourceId
        self.videoID = videoID
    }
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
    private let webSnapshotCapture: any WebSnapshotCapturing
    private let googleWorkspaceCapture: any GoogleWorkspaceCapturing

    public init(
        accountId: UUID,
        accountKey: Data,
        store: EpistoriaStore,
        directory: URL,
        api: EpistoriaAPIClient? = nil,
        webSnapshotCapture: any WebSnapshotCapturing = WebSnapshotCaptureService(),
        googleWorkspaceCapture: any GoogleWorkspaceCapturing = GoogleWorkspaceCaptureService()
    ) {
        self.accountId = accountId
        self.accountKey = accountKey
        self.store = store
        database = store.database
        self.directory = directory
        self.api = api
        self.webSnapshotCapture = webSnapshotCapture
        self.googleWorkspaceCapture = googleWorkspaceCapture
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
        return try await importImage(
            data: plaintext,
            filename: sourceURL.lastPathComponent.isEmpty ? "Imported image" : sourceURL.lastPathComponent
        )
    }

    /// Imports image bytes supplied by Photos, the clipboard, drag and drop, or a Share Sheet
    /// without placing decrypted content in a temporary file.
    public func importImage(data plaintext: Data, filename: String = "Imported image") async throws -> ImportedImage {
        guard plaintext.count <= 64 * 1_024 * 1_024 else { throw AssetManagerError.fileTooLarge }
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
        let safeFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported image"
            : String(filename.prefix(240))
        let imported = try await importAsset(
            plaintext: plaintext,
            mimeType: mimeType,
            originalFilename: safeFilename
        )
        return ImportedImage(
            assetId: imported.assetId,
            reusedExistingAsset: imported.reusedExistingAsset,
            filename: safeFilename,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    public func importSource(
        from sourceURL: URL,
        topicId: UUID? = nil,
        sessionId: UUID? = nil
    ) async throws -> ImportedResource {
        if sourceURL.pathExtension.lowercased() == "pdf" {
            return try await importPDF(from: sourceURL, courseId: topicId, sessionId: sessionId)
        }
        if let type = UTType(filenameExtension: sourceURL.pathExtension), type.conforms(to: .image) {
            let image = try await importImage(from: sourceURL)
            let sourceId = try await store.createSource(
                type: .image,
                title: sourceURL.deletingPathExtension().lastPathComponent,
                originalAssetId: image.assetId,
                primaryTopicId: topicId,
                sessionId: sessionId
            )
            return ImportedResource(
                resourceId: sourceId,
                assetId: image.assetId,
                reusedExistingAsset: image.reusedExistingAsset
            )
        }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let adapter = try SourceAdapterRegistry().adapter(for: sourceURL.lastPathComponent)
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw SourceAdapterError.malformed }
        if let size = values.fileSize, size > adapter.maximumBytes { throw SourceAdapterError.tooLarge }
        let plaintext = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let mimeType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        try await adapter.validateForImport(
            data: plaintext,
            filename: sourceURL.lastPathComponent,
            mimeType: mimeType
        )
        let imported = try await importAsset(
            plaintext: plaintext,
            mimeType: mimeType,
            originalFilename: sourceURL.lastPathComponent
        )
        let sourceId = try await store.createSource(
            type: adapter.sourceType,
            title: sourceURL.deletingPathExtension().lastPathComponent,
            originalAssetId: imported.assetId,
            primaryTopicId: topicId,
            sessionId: sessionId
        )
        return ImportedResource(
            resourceId: sourceId,
            assetId: imported.assetId,
            reusedExistingAsset: imported.reusedExistingAsset
        )
    }

    /// Imports bytes that are already in memory, including content drained from the encrypted
    /// Share extension inbox. Validation completes before a Source record is created.
    public func importSource(
        data plaintext: Data,
        filename: String,
        topicId: UUID? = nil,
        sessionId: UUID? = nil,
        identifiers: [String] = []
    ) async throws -> ImportedResource {
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let leafFilename = (trimmedFilename as NSString).lastPathComponent
            .replacingOccurrences(of: "\\", with: "-")
        let safeFilename = String(leafFilename.prefix(240))
        guard !safeFilename.isEmpty, safeFilename != ".", safeFilename != ".." else {
            throw SourceAdapterError.malformed
        }
        let extensionName = URL(fileURLWithPath: safeFilename).pathExtension.lowercased()
        let title = URL(fileURLWithPath: safeFilename).deletingPathExtension().lastPathComponent

        if extensionName == "pdf" {
            guard plaintext.count <= 512 * 1_024 * 1_024 else {
                throw AssetManagerError.fileTooLarge
            }
            guard plaintext.starts(with: Data("%PDF-".utf8)) else {
                throw AssetManagerError.notPDF
            }
            let imported = try await importAsset(
                plaintext: plaintext,
                mimeType: "application/pdf",
                originalFilename: safeFilename
            )
            let sourceId = try await store.createSource(
                type: .pdf,
                title: title.isEmpty ? "Imported PDF" : title,
                originalAssetId: imported.assetId,
                identifiers: identifiers,
                primaryTopicId: topicId,
                sessionId: sessionId
            )
            return ImportedResource(
                resourceId: sourceId,
                assetId: imported.assetId,
                reusedExistingAsset: imported.reusedExistingAsset
            )
        }
        if let type = UTType(filenameExtension: extensionName), type.conforms(to: .image) {
            let image = try await importImage(data: plaintext, filename: safeFilename)
            let sourceId = try await store.createSource(
                type: .image,
                title: title.isEmpty ? "Imported image" : title,
                originalAssetId: image.assetId,
                identifiers: identifiers,
                primaryTopicId: topicId,
                sessionId: sessionId
            )
            return ImportedResource(
                resourceId: sourceId,
                assetId: image.assetId,
                reusedExistingAsset: image.reusedExistingAsset
            )
        }

        let adapter = try SourceAdapterRegistry().adapter(for: safeFilename)
        guard plaintext.count <= adapter.maximumBytes else { throw SourceAdapterError.tooLarge }
        let mimeType = UTType(filenameExtension: extensionName)?.preferredMIMEType
            ?? "application/octet-stream"
        try await adapter.validateForImport(
            data: plaintext,
            filename: safeFilename,
            mimeType: mimeType
        )
        let imported = try await importAsset(
            plaintext: plaintext,
            mimeType: mimeType,
            originalFilename: safeFilename
        )
        let sourceId = try await store.createSource(
            type: adapter.sourceType,
            title: title.isEmpty ? "Imported Source" : title,
            originalAssetId: imported.assetId,
            identifiers: identifiers,
            primaryTopicId: topicId,
            sessionId: sessionId
        )
        return ImportedResource(
            resourceId: sourceId,
            assetId: imported.assetId,
            reusedExistingAsset: imported.reusedExistingAsset
        )
    }

    public func importPastedText(
        _ text: String,
        title: String? = nil,
        topicId: UUID? = nil,
        identifiers: [String] = []
    ) async throws -> ImportedResource {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty, let data = cleanText.data(using: .utf8) else {
            throw SourceAdapterError.containsNoReadableText
        }
        let adapter = PlainTextSourceAdapter(sourceType: .pastedText, extensions: ["txt"])
        try adapter.validate(data: data, filename: "Shared text.txt", mimeType: "text/plain")
        let imported = try await importAsset(
            plaintext: data,
            mimeType: "text/plain",
            originalFilename: "Shared text.txt"
        )
        let proposedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstLine = cleanText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let resolvedTitle = String((proposedTitle.isEmpty ? firstLine : proposedTitle).prefix(120))
        let sourceId = try await store.createSource(
            type: .pastedText,
            title: resolvedTitle.isEmpty ? "Shared text" : resolvedTitle,
            originalAssetId: imported.assetId,
            identifiers: identifiers,
            primaryTopicId: topicId
        )
        return ImportedResource(
            resourceId: sourceId,
            assetId: imported.assetId,
            reusedExistingAsset: imported.reusedExistingAsset
        )
    }

    /// Saves a validated HTTPS reference without fetching it. The owner can capture a frozen
    /// webpage version later from Library, which keeps sharing offline and network-transparent.
    @discardableResult
    public func importURLReference(
        _ url: URL,
        title: String? = nil,
        topicId: UUID? = nil,
        identifiers: [String] = []
    ) async throws -> UUID {
        let normalized = try WebSnapshotCaptureService.validatedURL(url)
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackTitle = normalized.host?.replacingOccurrences(of: "www.", with: "")
            ?? "Shared link"
        return try await store.createSource(
            type: .website,
            title: String((cleanTitle.isEmpty ? fallbackTitle : cleanTitle).prefix(240)),
            canonicalURL: normalized,
            capturedURL: normalized,
            identifiers: identifiers,
            primaryTopicId: topicId
        )
    }

    public func importWebSnapshot(
        from url: URL,
        topicId: UUID? = nil,
        sessionId: UUID? = nil
    ) async throws -> ImportedResource {
        let snapshot = try await webSnapshotCapture.capture(url: url)
        let adapter = WebSnapshotSourceAdapter()
        try adapter.validate(
            data: snapshot.data,
            filename: "snapshot.epistoriaweb",
            mimeType: snapshot.mimeType
        )
        let imported = try await importAsset(
            plaintext: snapshot.data,
            mimeType: snapshot.mimeType,
            originalFilename: webSnapshotFilename(for: snapshot.capturedURL)
        )
        let sourceId = try await store.createSource(
            type: .website,
            title: snapshot.title,
            originalAssetId: imported.assetId,
            canonicalURL: snapshot.requestedURL,
            capturedURL: snapshot.capturedURL,
            primaryTopicId: topicId,
            sessionId: sessionId
        )
        return ImportedResource(
            resourceId: sourceId,
            assetId: imported.assetId,
            reusedExistingAsset: imported.reusedExistingAsset
        )
    }

    public func refreshWebSnapshot(id sourceId: UUID) async throws -> RefreshedWebSnapshot {
        let source = try await store.payload(SourcePayload.self, id: sourceId).payload
        guard source.sourceType == .website, let canonicalURL = source.canonicalURL else {
            throw SourceAdapterError.unsupportedType
        }

        var previousText: String?
        if let previousAssetId = source.originalAssetId,
           let previousData = try? await decryptedData(assetId: previousAssetId) {
            previousText = try? WebSnapshotSourceAdapter().extractText(data: previousData)
        }

        let snapshot = try await webSnapshotCapture.capture(url: canonicalURL)
        let adapter = WebSnapshotSourceAdapter()
        try adapter.validate(
            data: snapshot.data,
            filename: "snapshot.epistoriaweb",
            mimeType: snapshot.mimeType
        )
        let imported = try await importAsset(
            plaintext: snapshot.data,
            mimeType: snapshot.mimeType,
            originalFilename: webSnapshotFilename(for: snapshot.capturedURL)
        )
        let versionId = try await store.refreshSource(
            id: sourceId,
            originalAssetId: imported.assetId,
            capturedURL: snapshot.capturedURL
        )
        return RefreshedWebSnapshot(
            versionId: versionId,
            capturedURL: snapshot.capturedURL,
            difference: WebSnapshotDifference(
                previousText: previousText,
                currentText: snapshot.readableText
            )
        )
    }

    public func importGoogleWorkspaceSnapshot(
        from url: URL,
        topicId: UUID? = nil,
        sessionId: UUID? = nil
    ) async throws -> ImportedResource {
        let snapshot = try await googleWorkspaceCapture.capture(url: url)
        let adapter = GoogleWorkspaceSourceAdapter(kind: snapshot.kind)
        try adapter.validate(
            data: snapshot.data,
            filename: googleWorkspaceFilename(for: snapshot),
            mimeType: snapshot.mimeType
        )
        let imported = try await importAsset(
            plaintext: snapshot.data,
            mimeType: snapshot.mimeType,
            originalFilename: googleWorkspaceFilename(for: snapshot)
        )
        let sourceId = try await store.createSource(
            type: snapshot.kind.sourceType,
            title: snapshot.title,
            originalAssetId: imported.assetId,
            canonicalURL: snapshot.canonicalURL,
            capturedURL: snapshot.capturedURL,
            primaryTopicId: topicId,
            sessionId: sessionId
        )
        return ImportedResource(
            resourceId: sourceId,
            assetId: imported.assetId,
            reusedExistingAsset: imported.reusedExistingAsset
        )
    }

    public func refreshGoogleWorkspaceSnapshot(
        id sourceId: UUID
    ) async throws -> RefreshedGoogleWorkspaceSnapshot {
        let source = try await store.payload(SourcePayload.self, id: sourceId).payload
        guard source.sourceType.isGoogleWorkspaceSource, let canonicalURL = source.canonicalURL else {
            throw SourceAdapterError.unsupportedType
        }

        let currentAdapter = try SourceAdapterRegistry().adapter(for: source.sourceType)
        var previousText: String?
        if let previousAssetId = source.originalAssetId,
           let previousData = try? await decryptedData(assetId: previousAssetId) {
            previousText = try? currentAdapter.extractText(data: previousData)
        }

        let snapshot = try await googleWorkspaceCapture.capture(url: canonicalURL)
        guard snapshot.kind.sourceType == source.sourceType else {
            throw SourceAdapterError.unsupportedType
        }
        let adapter = GoogleWorkspaceSourceAdapter(kind: snapshot.kind)
        try adapter.validate(
            data: snapshot.data,
            filename: googleWorkspaceFilename(for: snapshot),
            mimeType: snapshot.mimeType
        )
        let imported = try await importAsset(
            plaintext: snapshot.data,
            mimeType: snapshot.mimeType,
            originalFilename: googleWorkspaceFilename(for: snapshot)
        )
        let versionId = try await store.refreshSource(
            id: sourceId,
            originalAssetId: imported.assetId,
            capturedURL: snapshot.capturedURL
        )
        return RefreshedGoogleWorkspaceSnapshot(
            versionId: versionId,
            capturedURL: snapshot.capturedURL,
            difference: WebSnapshotDifference(
                previousText: previousText,
                currentText: snapshot.readableText
            )
        )
    }

    public func importYouTubeReference(
        from url: URL,
        title: String? = nil,
        topicId: UUID? = nil,
        sessionId: UUID? = nil
    ) async throws -> ImportedYouTubeReference {
        let reference = try YouTubeReference(url: url)
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceId = try await store.createSource(
            type: .youtube,
            title: cleanTitle.isEmpty ? "YouTube video" : String(cleanTitle.prefix(240)),
            canonicalURL: reference.canonicalURL,
            capturedURL: reference.playbackURL,
            identifiers: ["youtube:\(reference.videoID)"],
            primaryTopicId: topicId,
            sessionId: sessionId
        )
        return ImportedYouTubeReference(sourceId: sourceId, videoID: reference.videoID)
    }

    @discardableResult
    public func refreshSource(id sourceId: UUID, from sourceURL: URL) async throws -> UUID {
        let source = try await store.payload(SourcePayload.self, id: sourceId).payload
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "pdf" {
            guard source.sourceType == .pdf else { throw SourceAdapterError.unsupportedType }
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw AssetManagerError.notPDF }
            if let size = values.fileSize, size > 512 * 1_024 * 1_024 { throw AssetManagerError.fileTooLarge }
            let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            guard data.starts(with: Data("%PDF-".utf8)) else { throw AssetManagerError.notPDF }
            let imported = try await importAsset(
                plaintext: data,
                mimeType: "application/pdf",
                originalFilename: sourceURL.lastPathComponent
            )
            return try await store.refreshSource(id: sourceId, originalAssetId: imported.assetId)
        }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            guard source.sourceType == .image else { throw SourceAdapterError.unsupportedType }
            let imported = try await importImage(from: sourceURL)
            return try await store.refreshSource(id: sourceId, originalAssetId: imported.assetId)
        }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let adapter = try SourceAdapterRegistry().adapter(for: sourceURL.lastPathComponent)
        guard adapter.sourceType == source.sourceType else { throw SourceAdapterError.unsupportedType }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw SourceAdapterError.malformed }
        if let size = values.fileSize, size > adapter.maximumBytes { throw SourceAdapterError.tooLarge }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        try await adapter.validateForImport(
            data: data,
            filename: sourceURL.lastPathComponent,
            mimeType: mimeType
        )
        let imported = try await importAsset(
            plaintext: data,
            mimeType: mimeType,
            originalFilename: sourceURL.lastPathComponent
        )
        return try await store.refreshSource(id: sourceId, originalAssetId: imported.assetId)
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

    /// Decrypts an already cached Asset without starting a network restore. Use this for
    /// secondary previews and comparison surfaces where opening the view is not approval to
    /// download missing data.
    public func decryptedLocalData(assetId: UUID) async throws -> Data {
        let metadata = try await assetMetadata(id: assetId)
        guard let local = try await usableLocalAsset(id: assetId, metadata: metadata.payload) else {
            throw AssetManagerError.encryptedAssetUnavailable
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

    private func webSnapshotFilename(for url: URL) -> String {
        let host = (url.host ?? "webpage")
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber || character == "-" || character == "."
                    ? character
                    : "-"
            }
        let cleanHost = String(host).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return "\(cleanHost.isEmpty ? "webpage" : cleanHost)-snapshot.html"
    }

    private func googleWorkspaceFilename(for snapshot: GoogleWorkspaceSnapshot) -> String {
        let identifier = (try? GoogleWorkspaceReference(url: snapshot.canonicalURL).fileID)
            .map { String($0.prefix(80)) } ?? "workspace"
        return "google-\(identifier).\(snapshot.kind.exportFormat)"
    }

    private func createResource(
        title: String,
        assetId: UUID,
        courseId: UUID?,
        sessionId: UUID?
    ) async throws -> UUID {
        try await store.createSource(
            type: .pdf,
            title: title.isEmpty ? "Imported PDF" : title,
            originalAssetId: assetId,
            primaryTopicId: courseId,
            sessionId: sessionId
        )
    }
}
