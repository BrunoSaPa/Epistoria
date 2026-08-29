import Foundation
import Security

public enum SharedCaptureKind: String, Codable, CaseIterable, Sendable {
    case image = "IMAGE"
    case file = "FILE"
    case text = "TEXT"
    case link = "LINK"
}

public struct SharedCaptureItem: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: String
    public var id: UUID
    public var kind: SharedCaptureKind
    public var createdAt: Date
    public var filename: String?
    public var typeIdentifier: String?
    public var title: String?
    public var payload: Data

    public init(
        id: UUID = UUID(),
        kind: SharedCaptureKind,
        createdAt: Date = .now,
        filename: String? = nil,
        typeIdentifier: String? = nil,
        title: String? = nil,
        payload: Data
    ) {
        schemaVersion = "shared-capture/v1"
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.title = title
        self.payload = payload
    }
}

public enum SharedCaptureInboxError: Error, Equatable, LocalizedError {
    case unavailable
    case invalidKey
    case invalidItem
    case unsupportedVersion
    case itemTooLarge
    case inboxFull
    case itemNotFound

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Epistoria's private capture inbox is unavailable. Open Epistoria and try again."
        case .invalidKey:
            "The device-only capture key is unavailable. Open Epistoria and try again."
        case .invalidItem:
            "The shared item is invalid or could not be verified."
        case .unsupportedVersion:
            "This shared item was created by an unsupported Epistoria version."
        case .itemTooLarge:
            "Share items must be 32 MB or smaller. Larger files can be imported from Library."
        case .inboxFull:
            "The private capture inbox is full. Open Epistoria before sharing more items."
        case .itemNotFound:
            "The shared item is no longer in the capture inbox."
        }
    }
}

/// A device-local encrypted queue shared by the app and its Share extension.
///
/// The queue never contains the notebook account key or plaintext capture metadata. A package is
/// written atomically as one authenticated ciphertext. The main app validates and imports it only
/// after the notebook has unlocked.
public struct SharedCaptureInbox: @unchecked Sendable {
    public static let appGroupIdentifier = "group.com.epistoria.notebook"
    public static let maximumPayloadBytes = 32 * 1_024 * 1_024
    public static let maximumPendingItems = 100
    public static let maximumStoredBytes = 512 * 1_024 * 1_024

    public enum Location: String, Sendable {
        case pending = "Pending"
        case failed = "Failed"
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let crypto = AssetCrypto()

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public static func live(fileManager: FileManager = .default) -> SharedCaptureInbox? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        return SharedCaptureInbox(
            rootURL: container.appendingPathComponent("SharedCaptureInbox", isDirectory: true),
            fileManager: fileManager
        )
    }

    @discardableResult
    public func enqueue(_ item: SharedCaptureItem, key: Data) throws -> UUID {
        guard key.count == 32 else { throw SharedCaptureInboxError.invalidKey }
        guard item.schemaVersion == "shared-capture/v1",
              item.payload.count <= Self.maximumPayloadBytes,
              !item.payload.isEmpty,
              safeOptionalText(item.filename, maximumCharacters: 240),
              safeOptionalText(item.typeIdentifier, maximumCharacters: 240),
              safeOptionalText(item.title, maximumCharacters: 500)
        else {
            if item.payload.count > Self.maximumPayloadBytes {
                throw SharedCaptureInboxError.itemTooLarge
            }
            throw SharedCaptureInboxError.invalidItem
        }
        try prepareDirectories()
        let existing = try allPackageURLs()
        guard existing.count < Self.maximumPendingItems else {
            throw SharedCaptureInboxError.inboxFull
        }
        let storedBytes = try existing.reduce(into: 0) { total, url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            total += max(size, 0)
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(item)
        let encrypted = try crypto.encrypt(plaintext, key: key)
        guard storedBytes <= Self.maximumStoredBytes - encrypted.count else {
            throw SharedCaptureInboxError.inboxFull
        }

        let destination = packageURL(id: item.id, location: .pending)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SharedCaptureInboxError.invalidItem
        }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try encrypted.write(to: destination, options: options)
        try applyPrivatePermissions(to: destination)
        return item.id
    }

    public func identifiers(in location: Location) throws -> [UUID] {
        try prepareDirectories()
        return try packageURLs(in: location)
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    public func item(id: UUID, location: Location, key: Data) throws -> SharedCaptureItem {
        guard key.count == 32 else { throw SharedCaptureInboxError.invalidKey }
        let url = packageURL(id: id, location: location)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SharedCaptureInboxError.itemNotFound
        }
        let encrypted = try Data(contentsOf: url, options: .mappedIfSafe)
        let plaintext = try crypto.decrypt(encrypted, key: key)
        let item = try PropertyListDecoder().decode(SharedCaptureItem.self, from: plaintext)
        guard item.schemaVersion == "shared-capture/v1" else {
            throw SharedCaptureInboxError.unsupportedVersion
        }
        guard item.id == id,
              !item.payload.isEmpty,
              item.payload.count <= Self.maximumPayloadBytes,
              safeOptionalText(item.filename, maximumCharacters: 240),
              safeOptionalText(item.typeIdentifier, maximumCharacters: 240),
              safeOptionalText(item.title, maximumCharacters: 500)
        else { throw SharedCaptureInboxError.invalidItem }
        return item
    }

    public func remove(id: UUID, from location: Location) throws {
        let url = packageURL(id: id, location: location)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func markFailed(id: UUID) throws {
        try move(id: id, from: .pending, to: .failed)
    }

    public func retryFailed() throws {
        for id in try identifiers(in: .failed) {
            try move(id: id, from: .failed, to: .pending)
        }
    }

    public func removeAllFailed() throws {
        for id in try identifiers(in: .failed) {
            try remove(id: id, from: .failed)
        }
    }

    private func move(id: UUID, from source: Location, to destination: Location) throws {
        try prepareDirectories()
        let sourceURL = packageURL(id: id, location: source)
        let destinationURL = packageURL(id: id, location: destination)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw SharedCaptureInboxError.itemNotFound
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw SharedCaptureInboxError.invalidItem
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func prepareDirectories() throws {
        for location in [Location.pending, .failed] {
            let url = directoryURL(location)
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try applyPrivatePermissions(to: url)
        }
    }

    private func allPackageURLs() throws -> [URL] {
        try packageURLs(in: .pending) + packageURLs(in: .failed)
    }

    private func packageURLs(in location: Location) throws -> [URL] {
        let directory = directoryURL(location)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.pathExtension == "capture",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  )
            else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private func directoryURL(_ location: Location) -> URL {
        rootURL.appendingPathComponent(location.rawValue, isDirectory: true)
    }

    private func packageURL(id: UUID, location: Location) -> URL {
        directoryURL(location)
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("capture")
    }

    private func safeOptionalText(_ value: String?, maximumCharacters: Int) -> Bool {
        guard let value else { return true }
        return !value.contains("\0") && value.count <= maximumCharacters
    }

    private func applyPrivatePermissions(to url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            attributes[.posixPermissions] = 0o700
        }
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }
}

public final class SharedCaptureKeyStore: @unchecked Sendable {
    public static let service = "com.epistoria.shared-capture-key"
    public static let account = "device-local-v1"

    private let accessGroup: String?
    private let service: String
    private let account: String

    public init(
        accessGroup: String?,
        service: String = SharedCaptureKeyStore.service,
        account: String = SharedCaptureKeyStore.account
    ) {
        self.accessGroup = accessGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.service = service
        self.account = account
    }

    public static func configured(bundle: Bundle = .main) -> SharedCaptureKeyStore {
        SharedCaptureKeyStore(
            accessGroup: bundle.object(
                forInfoDictionaryKey: "EpistoriaShareKeychainAccessGroup"
            ) as? String
        )
    }

    public func loadOrCreate() throws -> Data {
        if let existing = try load() { return existing }
        let key = try EntityCrypto().randomKey()
        var item = baseQuery()
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return key
    }

    public func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let key = result as? Data, key.count == 32 else {
            throw KeychainStoreError.invalidData
        }
        return key
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
